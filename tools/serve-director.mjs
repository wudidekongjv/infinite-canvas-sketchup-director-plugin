// 无依赖的导演台静态服务：node tools/serve-director.mjs [端口]
// 作用是把仓库里的 director/ 目录原样提供出来，供画布节点 iframe 加载。
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "director");
const port = Number(process.argv[2] || process.env.PORT || 5199);

if (!fs.existsSync(path.join(root, "index.html"))) {
    console.error("找不到 director/index.html，请确认脚本位于仓库 tools/ 下");
    process.exit(1);
}

const MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".glb": "model/gltf-binary",
    ".gltf": "model/gltf+json",
    ".fbx": "application/octet-stream",
    ".obj": "text/plain; charset=utf-8",
    ".mtl": "text/plain; charset=utf-8",
    ".wasm": "application/wasm",
    ".bin": "application/octet-stream",
    ".hdr": "application/octet-stream",
    ".txt": "text/plain; charset=utf-8",
    ".woff2": "font/woff2",
    ".ico": "image/x-icon",
};

function send(res, status, body, type) {
    res.writeHead(status, {
        "Content-Type": type || "text/plain; charset=utf-8",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "*",
        "Cache-Control": "no-store",
    });
    res.end(body);
}

const server = http.createServer((req, res) => {
    if (req.method === "OPTIONS") {
        res.writeHead(204, {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "*",
            "Access-Control-Allow-Methods": "GET,HEAD,OPTIONS",
        });
        res.end();
        return;
    }

    let pathname = "/";
    try {
        pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
    } catch {
        send(res, 400, "bad url");
        return;
    }

    if (pathname === "/" || pathname === "") pathname = "/index.html";

    const filePath = path.resolve(root, "." + pathname);
    if (!filePath.startsWith(root)) {
        send(res, 403, "forbidden");
        return;
    }

    fs.stat(filePath, (err, stat) => {
        if (err || !stat.isFile()) {
            send(res, 404, "not found: " + pathname);
            return;
        }
        const ext = path.extname(filePath).toLowerCase();
        const type = MIME[ext] || "application/octet-stream";
        if (req.method === "HEAD") {
            res.writeHead(200, {
                "Content-Type": type,
                "Content-Length": stat.size,
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store",
            });
            res.end();
            return;
        }
        res.writeHead(200, {
            "Content-Type": type,
            "Content-Length": stat.size,
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        });
        fs.createReadStream(filePath).pipe(res);
    });
});

server.on("error", (error) => {
    if (error.code === "EADDRINUSE") {
        console.error("端口 " + port + " 已被占用");
    } else {
        console.error(String(error));
    }
    process.exit(1);
});

server.listen(port, "127.0.0.1", () => {
    console.log("director served at http://127.0.0.1:" + port + "/  root=" + root);
});
