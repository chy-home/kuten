const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const host = process.env.HOST || "127.0.0.1";
const port = Number(process.env.PORT || 3000);
const rootDir = __dirname;

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".ico": "image/x-icon"
};

function send(response, statusCode, body, contentType) {
  response.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store"
  });
  response.end(body);
}

function resolveFile(requestUrl) {
  const safeUrl = new URL(requestUrl, "http://127.0.0.1");
  const pathname = decodeURIComponent(safeUrl.pathname);
  const relativePath = pathname === "/" ? "/index.html" : pathname;
  const absolutePath = path.normalize(path.join(rootDir, relativePath));

  if (!absolutePath.startsWith(rootDir)) {
    return null;
  }

  return absolutePath;
}

const server = http.createServer((request, response) => {
  const parsedUrl = new URL(request.url, "http://127.0.0.1");
  const pathname = decodeURIComponent(parsedUrl.pathname);

  if (request.method === "POST" && pathname === "/api/save-chapters") {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try {
        const data = JSON.parse(body);
        const filePath = path.join(rootDir, "datas", "chapters.json");
        fs.writeFile(filePath, JSON.stringify(data, null, 2), "utf-8", (err) => {
          if (err) {
            send(response, 500, JSON.stringify({ error: "Write failed" }), "application/json; charset=utf-8");
            return;
          }
          send(response, 200, JSON.stringify({ ok: true }), "application/json; charset=utf-8");
        });
      } catch (e) {
        send(response, 400, JSON.stringify({ error: "Invalid JSON" }), "application/json; charset=utf-8");
      }
    });
    return;
  }

  if (request.method === "POST" && pathname === "/api/save-styles") {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try {
        const data = JSON.parse(body);
        const filePath = path.join(rootDir, "datas", "styles.json");
        fs.writeFile(filePath, JSON.stringify(data, null, 2), "utf-8", (err) => {
          if (err) {
            send(response, 500, JSON.stringify({ error: "Write failed" }), "application/json; charset=utf-8");
            return;
          }
          send(response, 200, JSON.stringify({ ok: true }), "application/json; charset=utf-8");
        });
      } catch (e) {
        send(response, 400, JSON.stringify({ error: "Invalid JSON" }), "application/json; charset=utf-8");
      }
    });
    return;
  }

  if (request.method === "POST" && pathname === "/api/save-scenes") {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try {
        const data = JSON.parse(body);
        const filePath = path.join(rootDir, "datas", "scenes.json");
        fs.writeFile(filePath, JSON.stringify(data, null, 2), "utf-8", (err) => {
          if (err) {
            send(response, 500, JSON.stringify({ error: "Write failed" }), "application/json; charset=utf-8");
            return;
          }
          send(response, 200, JSON.stringify({ ok: true }), "application/json; charset=utf-8");
        });
      } catch (e) {
        send(response, 400, JSON.stringify({ error: "Invalid JSON" }), "application/json; charset=utf-8");
      }
    });
    return;
  }

  if (request.method === "POST" && pathname === "/api/proxy") {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try {
        const parsed = JSON.parse(body);
        const { url, method: proxyMethod } = parsed;

        const apiKey = parsed.apiKey || "";
        const proxyBody = parsed.body || null;

        if (!url) {
          send(response, 400, JSON.stringify({ error: "Missing url" }), "application/json; charset=utf-8");
          return;
        }

        const targetUrl = new URL(url);
        const isHttps = targetUrl.protocol === "https:";
        const httpModule = isHttps ? https : http;

        const proxyHeaders = {
          "Content-Type": "application/json"
        };
        if (apiKey) {
          proxyHeaders["Authorization"] = "Bearer " + apiKey;
        }
        if (parsed.headers && typeof parsed.headers === "object") {
          Object.entries(parsed.headers).forEach(([key, value]) => {
            proxyHeaders[key] = value;
          });
        }

        const options = {
          hostname: targetUrl.hostname,
          port: targetUrl.port || (isHttps ? 443 : 80),
          path: targetUrl.pathname + targetUrl.search,
          method: proxyMethod || "POST",
          headers: proxyHeaders
        };

        const proxyReq = httpModule.request(options, (proxyRes) => {
          const contentType = proxyRes.headers["content-type"] || "";
          const isStream = contentType.includes("text/event-stream");

          if (isStream) {
            response.writeHead(proxyRes.statusCode, {
              "Content-Type": "text/event-stream",
              "Cache-Control": "no-cache",
              "Connection": "keep-alive",
              "Access-Control-Allow-Origin": "*"
            });
            proxyRes.pipe(response);
          } else {
            let data = "";
            proxyRes.on("data", (chunk) => { data += chunk; });
            proxyRes.on("end", () => {
              response.writeHead(proxyRes.statusCode, {
                "Content-Type": contentType || "application/json; charset=utf-8",
                "Access-Control-Allow-Origin": "*"
              });
              response.end(data);
            });
          }
        });

        proxyReq.on("error", (err) => {
          send(response, 502, JSON.stringify({ error: "Proxy error: " + err.message }), "application/json; charset=utf-8");
        });

        if (proxyBody) {
          proxyReq.write(JSON.stringify(proxyBody));
        }
        proxyReq.end();
      } catch (e) {
        send(response, 400, JSON.stringify({ error: "Invalid proxy request" }), "application/json; charset=utf-8");
      }
    });
    return;
  }

  const filePath = resolveFile(request.url);

  if (!filePath) {
    send(response, 403, "Forbidden", "text/plain; charset=utf-8");
    return;
  }

  fs.readFile(filePath, (error, fileBuffer) => {
    if (error) {
      if (error.code === "ENOENT") {
        send(response, 404, "Not Found", "text/plain; charset=utf-8");
        return;
      }

      send(response, 500, "Internal Server Error", "text/plain; charset=utf-8");
      return;
    }

    const extension = path.extname(filePath).toLowerCase();
    const contentType = mimeTypes[extension] || "application/octet-stream";
    send(response, 200, fileBuffer, contentType);
  });
});

server.listen(port, host, () => {
  console.log("Magnum Novel Studio running at http://" + host + ":" + port);
});
