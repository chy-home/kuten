const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const vm = require("node:vm");
const { spawn } = require("node:child_process");

const rootDir = path.resolve(__dirname, "..");
const cachePath = path.join(rootDir, "data", "catch.json");
const rememberPath = path.join(rootDir, "ignore.txt");
const appPath = path.join(rootDir, "app.js");
const port = 18080;
const baseUrl = `http://localhost:${port}`;

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

async function main() {
  const originalCache = await fs.readFile(cachePath, "utf8");
  const originalRemember = await readOptionalTextFile(rememberPath);
  const server = spawn(process.execPath, ["server.js"], {
    cwd: rootDir,
    env: {
      ...process.env,
      PORT: String(port)
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  try {
    await fs.writeFile(rememberPath, "remembered\nsynced\n");
    await waitForServer(server);
    await postJson("/api/lookup-cache", {
      items: {
        "combo:cacheword:": {
          ipa: "/cache-word/",
          meaning: "来自文件缓存"
        }
      }
    });

    const savedCache = await getJson("/data/catch.json");
    assert.equal(savedCache.items["combo:cacheword:"].meaning, "来自文件缓存");

    const appContext = await runAppInBrowserLikeContext();
    assert.equal(appContext.document.elements.knownWords.value, "remembered\nsynced\n");
    appContext.document.elements.sourceText.value = "cacheword";
    await appContext.document.elements.extractButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /单词\tcacheword\t1\t.*\t待补充释义\t/);
    assert.doesNotMatch(appContext.document.elements.summary.textContent, /复用缓存/);
    assert.equal(appContext.document.elements.translateButton.disabled, true);
    assert.equal(appContext.externalFetches.length, 0);

    appContext.document.elements.useOnlineModel.checked = true;
    await appContext.document.elements.useOnlineModel.dispatch("change");
    await appContext.document.elements.extractButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /单词\tcacheword\t1\t\/cache-word\/\t来自文件缓存\t/);
    assert.match(appContext.document.elements.summary.textContent, /复用缓存 1 条/);
    assert.equal(appContext.externalFetches.length, 0);

    appContext.document.elements.sourceText.value = "freshword";
    await appContext.document.elements.extractButton.dispatch("click");
    await appContext.document.elements.translateButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /单词\tfreshword\t1\t.*\t在线翻译结果\t/);
    assert.ok(appContext.timeoutDelays.some((delay) => delay >= 800 && delay <= 2200));

    appContext.nextExternalTranslation = "sameword";
    appContext.document.elements.sourceText.value = "sameword";
    await appContext.document.elements.extractButton.dispatch("click");
    await appContext.document.elements.translateButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /单词\tsameword\t1\t.*\t待补充释义\t/);
    appContext.nextExternalTranslation = "在线翻译结果";

    const fetchCountBeforeOnlineDisabled = appContext.externalFetches.length;
    appContext.document.elements.useOnlineModel.checked = false;
    await appContext.document.elements.useOnlineModel.dispatch("change");
    appContext.document.elements.sourceText.value = "offlineword";
    await appContext.document.elements.extractButton.dispatch("click");
    await appContext.document.elements.translateButton.dispatch("click");

    assert.equal(appContext.externalFetches.length, fetchCountBeforeOnlineDisabled);
    assert.match(appContext.document.elements.summary.textContent, /已关闭在线模型/);
    assert.equal(appContext.document.elements.translateButton.disabled, true);

    appContext.document.elements.knownWords.value = "task\nknownword";
    await appContext.document.elements.knownWords.dispatch("input");
    appContext.document.elements.sourceText.value = "knownword tasks unknownword unknownword knownword tasks";
    await appContext.document.elements.extractButton.dispatch("click");

    const knownWordsResultLines = appContext.document.elements.resultText.value.split("\n");
    assert.equal(knownWordsResultLines.length, 2);
    assert.equal(knownWordsResultLines[0], "序号\t类型\t内容\t次数\t音标\t释义\t词根记忆");
    assert.match(appContext.document.elements.resultText.value, /单词\tunknownword\t2\t.*\t.*\t/);
    assert.doesNotMatch(appContext.document.elements.resultText.value, /单词\tknownword\t/);
    assert.doesNotMatch(appContext.document.elements.resultText.value, /单词\ttasks\t/);

    appContext.document.elements.includePhrases.checked = true;
    appContext.document.elements.sourceText.value = "real time delivery";
    await appContext.document.elements.extractButton.dispatch("click");
    assert.match(appContext.document.elements.resultText.value, /短语\treal time\t.*\t.*\t.*\t1$/m);
    appContext.document.elements.sourceText.value = "alpha beta alpha beta";
    await appContext.document.elements.extractButton.dispatch("click");
    assert.doesNotMatch(appContext.document.elements.resultText.value, /短语\talpha beta\t/);
    appContext.document.elements.includePhrases.checked = false;

    appContext.document.elements.knownWords.value = "";
    appContext.document.elements.sourceText.value = "freshword keepword keepword";
    await appContext.document.elements.extractButton.dispatch("click");

    const initialRows = appContext.document.elements.resultText.value.split("\n");
    assert.equal(initialRows[0], "序号\t类型\t内容\t音标\t释义\t词根记忆\t次数");

    const thirdHeaderCell = appContext.document.elements.resultTableHeadRow.children[2];
    await thirdHeaderCell.children[0].children[1].dispatch("click");
    const hiddenTermRows = appContext.document.elements.resultText.value.split("\n");
    assert.equal(hiddenTermRows[0], "序号\t类型\t音标\t释义\t词根记忆\t次数");

    await appContext.document.elements.resetTableViewButton.dispatch("click");
    const restoredTermRows = appContext.document.elements.resultText.value.split("\n");
    assert.equal(restoredTermRows[0], "序号\t类型\t内容\t音标\t释义\t词根记忆\t次数");

    const countHeaderCell = appContext.document.elements.resultTableHeadRow.children[6];
    await countHeaderCell.children[0].dispatch("click");
    const sortedRows = appContext.document.elements.resultText.value.split("\n");
    assert.match(sortedRows[1], /^1\t单词\tfreshword\t.*\t1$/);
    assert.match(sortedRows[2], /^2\t单词\tkeepword\t.*\t2$/);

    const firstHeaderCell = appContext.document.elements.resultTableHeadRow.children[0];
    const latestCountHeaderCell = appContext.document.elements.resultTableHeadRow.children[6];
    const dragTransfer = createDataTransfer();
    await firstHeaderCell.dispatch("dragstart", { dataTransfer: dragTransfer });
    await latestCountHeaderCell.dispatch("dragover", { dataTransfer: dragTransfer });
    await latestCountHeaderCell.dispatch("drop", { dataTransfer: dragTransfer });
    const movedHeader = appContext.document.elements.resultText.value.split("\n")[0];
    assert.equal(movedHeader, "类型\t内容\t音标\t释义\t词根记忆\t次数\t序号");

    appContext.document.elements.knownWords.value = "freshword";
    await appContext.document.elements.trimKnownWordsButton.dispatch("click");

    assert.doesNotMatch(appContext.document.elements.resultText.value, /单词\tfreshword\t/);
    assert.match(appContext.document.elements.resultText.value, /单词\tkeepword\t.*\t2\t1$/);
    assert.match(appContext.document.elements.summary.textContent, /已裁剪/);

    console.log("cache flow ok");
  } finally {
    server.kill();
    await waitForExit(server);
    await fs.writeFile(cachePath, originalCache);
    await restoreOptionalTextFile(rememberPath, originalRemember);
  }
}

async function runAppInBrowserLikeContext() {
  const elements = createElements();
  const externalFetches = [];
  const timeoutDelays = [];
  const context = {
    console,
    Blob,
    URL: {
      createObjectURL: () => "blob:test",
      revokeObjectURL: () => {}
    },
    Date,
    Error,
    JSON,
    localStorage: createLocalStorage(),
    Map,
    Math,
    Number,
    Object,
    Promise,
    RegExp,
    Set,
    String,
    Array,
    location: {
      protocol: "http:"
    },
    setTimeout(callback, delay) {
      timeoutDelays.push(delay);
      callback();
      return 1;
    },
    navigator: {
      clipboard: {
        writeText: async () => {}
      }
    },
    window: {
      isSecureContext: true
    },
    nextExternalTranslation: "在线翻译结果",
    document: {
      elements,
      getElementById(id) {
        return elements[id];
      },
      createElement(tagName) {
        return createElement(tagName);
      }
    },
    fetch: async (url, options) => {
      const resolvedUrl = new URL(url, baseUrl);
      if (resolvedUrl.origin !== baseUrl) {
        externalFetches.push(resolvedUrl.href);
        return createJsonResponse({
          responseData: {
            translatedText: context.nextExternalTranslation
          }
        });
      }

      return fetch(resolvedUrl.href, options);
    }
  };

  vm.createContext(context);
  vm.runInContext(await fs.readFile(appPath, "utf8"), context, {
    filename: appPath
  });
  await Promise.resolve();
  await context.window.__appStartupReady;

  return Object.assign(context, {
    externalFetches,
    timeoutDelays
  });
}

async function readOptionalTextFile(filePath) {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function restoreOptionalTextFile(filePath, content) {
  if (content === null) {
    try {
      await fs.unlink(filePath);
    } catch (error) {
      if (!error || error.code !== "ENOENT") {
        throw error;
      }
    }
    return;
  }

  await fs.writeFile(filePath, content);
}

function createElements() {
  return {
    sourceText: createElement("textarea", { value: "" }),
    resultText: createElement("textarea", { value: "" }),
    resultTable: createElement("table", { hidden: true }),
    resultTableHeadRow: createElement("tr"),
    resultTableBody: createElement("tbody"),
    resultEmptyState: createElement("div", { textContent: "" }),
    summary: createElement("div", { textContent: "" }),
    txtFile: createElement("input", { value: "", files: [] }),
    extractButton: createElement("button"),
    translateButton: createElement("button"),
    clearButton: createElement("button"),
    copyButton: createElement("button"),
    downloadButton: createElement("button"),
    minWordLength: createElement("input", { value: "3" }),
    excludeStopwords: createElement("input", { checked: true }),
    includePhrases: createElement("input", { checked: false }),
    useOnlineModel: createElement("input", { checked: true }),
    onlineProvider: createElement("select", { value: "combo" }),
    translationEndpoint: createElement("input", { value: "" }),
    translationApiKey: createElement("input", { value: "" }),
    knownWords: createElement("textarea", { value: "" }),
    trimKnownWordsButton: createElement("button"),
    resetTableViewButton: createElement("button")
  };
}

function createLocalStorage() {
  const items = new Map();
  return {
    getItem(key) {
      return items.has(key) ? items.get(key) : null;
    },
    setItem(key, value) {
      items.set(key, String(value));
    }
  };
}

function createJsonResponse(data, ok = true) {
  return {
    ok,
    status: ok ? 200 : 500,
    async json() {
      return data;
    }
  };
}

function createElement(tagName, initialValues = {}) {
  const listeners = new Map();
  const classNames = new Set();
  const element = {
    tagName,
    value: "",
    textContent: "",
    hidden: false,
    checked: false,
    files: [],
    href: "",
    download: "",
    placeholder: "",
    disabled: false,
    className: "",
    type: "",
    title: "",
    draggable: false,
    dataset: {},
    children: [],
    classList: {
      add(...names) {
        names.filter(Boolean).forEach((name) => classNames.add(name));
        element.className = [...classNames].join(" ");
      },
      remove(...names) {
        names.filter(Boolean).forEach((name) => classNames.delete(name));
        element.className = [...classNames].join(" ");
      }
    },
    addEventListener(eventName, listener) {
      listeners.set(eventName, listener);
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    async dispatch(eventName, extraEvent = {}) {
      const listener = listeners.get(eventName);
      if (listener) {
        await listener(Object.assign({
          target: this,
          currentTarget: this,
          preventDefault() {},
          stopPropagation() {}
        }, extraEvent));
      }
    },
    async setChecked(checked) {
      this.checked = checked;
      await this.dispatch("change");
    },
    click() {},
    focus() {},
    select() {}
  };

  Object.defineProperty(element, "innerHTML", {
    get() {
      return "";
    },
    set() {
      this.children = [];
    }
  });

  return Object.assign(element, initialValues);
}

function createDataTransfer() {
  const values = new Map();
  return {
    effectAllowed: "",
    dropEffect: "",
    setData(type, value) {
      values.set(type, value);
    },
    getData(type) {
      return values.get(type) || "";
    }
  };
}

function postJson(pathname, data) {
  return request("POST", pathname, JSON.stringify(data), {
    "Content-Type": "application/json"
  }).then((response) => JSON.parse(response.body));
}

function getJson(pathname) {
  return request("GET", pathname).then((response) => JSON.parse(response.body));
}

function request(method, pathname, body = "", headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      `${baseUrl}${pathname}`,
      {
        method,
        headers
      },
      (response) => {
        let responseBody = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          responseBody += chunk;
        });
        response.on("end", () => {
          resolve({
            statusCode: response.statusCode,
            body: responseBody
          });
        });
      }
    );

    request.on("error", reject);
    if (body) {
      request.write(body);
    }
    request.end();
  });
}

function waitForServer(server) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Server did not start in time"));
    }, 5000);

    server.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`Server exited before readiness with code ${code}`));
    });

    server.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("Serving on")) {
        clearTimeout(timeout);
        resolve();
      }
    });
  });
}

function waitForExit(childProcess) {
  return new Promise((resolve) => {
    if (childProcess.exitCode !== null || childProcess.signalCode !== null) {
      resolve();
      return;
    }

    childProcess.once("exit", resolve);
  });
}
