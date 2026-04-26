const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const vm = require("node:vm");
const { spawn } = require("node:child_process");

const rootDir = path.resolve(__dirname, "..");
const cachePath = path.join(rootDir, "data", "catch.json");
const appPath = path.join(rootDir, "app.js");
const port = 18080;
const baseUrl = `http://localhost:${port}`;

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

async function main() {
  const originalCache = await fs.readFile(cachePath, "utf8");
  const server = spawn(process.execPath, ["server.js"], {
    cwd: rootDir,
    env: {
      ...process.env,
      PORT: String(port)
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  try {
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
    appContext.document.elements.sourceText.value = "cacheword";
    await appContext.document.elements.extractButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /cacheword \/cache-word\/ 来自文件缓存/);
    assert.match(appContext.document.elements.summary.textContent, /复用缓存 1 条/);
    assert.equal(appContext.externalFetches.length, 0);

    appContext.document.elements.sourceText.value = "freshword";
    await appContext.document.elements.extractButton.dispatch("click");
    await appContext.document.elements.translateButton.dispatch("click");

    assert.match(appContext.document.elements.resultText.value, /freshword .* 在线翻译结果/);
    assert.ok(appContext.timeoutDelays.some((delay) => delay >= 800 && delay <= 2200));

    console.log("cache flow ok");
  } finally {
    server.kill();
    await waitForExit(server);
    await fs.writeFile(cachePath, originalCache);
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
            translatedText: "在线翻译结果"
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

  return {
    ...context,
    externalFetches,
    timeoutDelays
  };
}

function createElements() {
  return {
    sourceText: createElement("textarea", { value: "" }),
    resultText: createElement("textarea", { value: "" }),
    summary: createElement("div", { textContent: "" }),
    txtFile: createElement("input", { value: "", files: [] }),
    extractButton: createElement("button"),
    translateButton: createElement("button"),
    clearButton: createElement("button"),
    copyButton: createElement("button"),
    downloadButton: createElement("button"),
    minWordLength: createElement("input", { value: "3" }),
    minPhraseFrequency: createElement("input", { value: "2" }),
    excludeStopwords: createElement("input", { checked: true }),
    includePhrases: createElement("input", { checked: true }),
    onlineProvider: createElement("select", { value: "combo" }),
    translationEndpoint: createElement("input", { value: "" }),
    translationApiKey: createElement("input", { value: "" })
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
  return {
    tagName,
    value: "",
    textContent: "",
    checked: false,
    files: [],
    href: "",
    download: "",
    placeholder: "",
    ...initialValues,
    addEventListener(eventName, listener) {
      listeners.set(eventName, listener);
    },
    async dispatch(eventName) {
      const listener = listeners.get(eventName);
      if (listener) {
        await listener({ target: this });
      }
    },
    click() {},
    focus() {},
    select() {}
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
