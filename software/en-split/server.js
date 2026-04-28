const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");

const rootDir = __dirname;
const cachePath = path.join(rootDir, "data", "catch.json");
const port = Number(process.env.PORT) || 8080;

const mimeTypes = {
  ".css": "text/css;charset=utf-8",
  ".html": "text/html;charset=utf-8",
  ".js": "text/javascript;charset=utf-8",
  ".json": "application/json;charset=utf-8",
  ".txt": "text/plain;charset=utf-8"
};

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host}`);

    if (request.method === "POST" && url.pathname === "/api/lookup-cache") {
      await handleLookupCacheWrite(request, response);
      return;
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      sendText(response, 405, "Method Not Allowed");
      return;
    }

    await serveStaticFile(url.pathname, request, response);
  } catch (error) {
    sendText(response, 500, "Internal Server Error");
  }
});

server.listen(port, () => {
  console.log(`Serving on http://localhost:${port}`);
});

async function handleLookupCacheWrite(request, response) {
  const body = await readRequestBody(request, 1024 * 1024 * 4);
  const payload = JSON.parse(body || "{}");
  const normalizedPayload = normalizeCachePayload(payload);

  await fs.mkdir(path.dirname(cachePath), { recursive: true });
  await fs.writeFile(cachePath, `${JSON.stringify(normalizedPayload, null, 2)}\n`);

  sendJson(response, 200, {
    ok: true,
    count: Object.keys(normalizedPayload.items).length
  });
}

async function serveStaticFile(urlPath, request, response) {
  const pathname = decodeURIComponent(urlPath === "/" ? "/index.html" : urlPath);
  const filePath = path.resolve(rootDir, `.${pathname}`);

  if (!filePath.startsWith(`${rootDir}${path.sep}`) && filePath !== rootDir) {
    sendText(response, 403, "Forbidden");
    return;
  }

  try {
    const stat = await fs.stat(filePath);
    if (!stat.isFile()) {
      sendText(response, 404, "Not Found");
      return;
    }

    const contentType = mimeTypes[path.extname(filePath)] || "application/octet-stream";
    response.writeHead(200, {
      "Content-Type": contentType,
      "Cache-Control": shouldDisableCache(pathname) ? "no-store" : "no-cache"
    });

    if (request.method === "HEAD") {
      response.end();
      return;
    }

    response.end(await fs.readFile(filePath));
  } catch (error) {
    sendText(response, 404, "Not Found");
  }
}

function readRequestBody(request, maxBytes) {
  return new Promise((resolve, reject) => {
    let body = "";

    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body, "utf8") > maxBytes) {
        reject(new Error("Request body is too large"));
        request.destroy();
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function normalizeCachePayload(payload) {
  const items = {};
  const sourceItems = payload && typeof payload === "object" && payload.items
    ? payload.items
    : {};

  for (const [key, value] of Object.entries(sourceItems)) {
    if (!value || typeof value !== "object") {
      continue;
    }

    const ipa = typeof value.ipa === "string" ? value.ipa : "";
    const meaning = typeof value.meaning === "string" ? value.meaning : "";
    if (!ipa && !meaning) {
      continue;
    }

    items[key] = { ipa, meaning };
  }

  return {
    version: 1,
    updatedAt: new Date().toISOString(),
    items
  };
}

function shouldDisableCache(pathname) {
  return pathname === "/data/catch.json" || pathname === "/ignore.txt";
}

function sendJson(response, statusCode, data) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json;charset=utf-8"
  });
  response.end(JSON.stringify(data));
}

function sendText(response, statusCode, text) {
  response.writeHead(statusCode, {
    "Content-Type": "text/plain;charset=utf-8"
  });
  response.end(text);
}
