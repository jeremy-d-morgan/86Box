const http = require("http");
const fs = require("fs");
const path = require("path");
const net = require("net");
const { WebSocketServer } = require("./node_modules/ws");

// --- Configuration ---
const WEB_PORT = 8080;
const VNC_HOST = "127.0.0.1";
const VNC_PORT = 5900;

// --- Static file server ---
const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".json": "application/json",
};

function serveStatic(req, res) {
  let url = req.url === "/" ? "/index.html" : req.url;

  // Serve noVNC library files from local novnc/ directory (browser ESM source)
  let filePath;
  if (url.startsWith("/novnc/")) {
    filePath = path.join(__dirname, "novnc", url.slice("/novnc/".length));
  } else {
    filePath = path.join(__dirname, url);
  }

  const ext = path.extname(filePath);
  const mime = MIME[ext] || "application/octet-stream";

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    res.writeHead(200, { "Content-Type": mime });
    res.end(data);
  });
}

const httpServer = http.createServer(serveStatic);

// --- WebSocket-to-VNC proxy ---
const wss = new WebSocketServer({
  server: httpServer,
  path: "/websockify",
  handleProtocols: (protocols) => {
    if (protocols.has("binary")) return "binary";
    return false;
  },
});

wss.on("connection", (ws) => {
  console.log("[ws] Client connected, bridging to VNC at %s:%d", VNC_HOST, VNC_PORT);

  let vnc = null;
  let retries = 0;
  const MAX_RETRIES = 20;
  const RETRY_DELAY_MS = 500;

  function connectVnc() {
    if (ws.readyState !== ws.OPEN) return;

    vnc = net.createConnection({ host: VNC_HOST, port: VNC_PORT });

    vnc.on("connect", () => {
      console.log("[vnc] Connected to VNC server (attempt %d)", retries + 1);
      retries = 0;
    });

    vnc.on("data", (data) => {
      if (ws.readyState === ws.OPEN) {
        ws.send(data, { binary: true });
      }
    });

    vnc.on("close", () => {
      console.log("[vnc] VNC connection closed");
      ws.close();
    });

    vnc.on("error", (err) => {
      if (err.code === "ECONNREFUSED" && retries < MAX_RETRIES) {
        retries++;
        console.log("[vnc] VNC not ready, retrying in %dms (attempt %d/%d)...", RETRY_DELAY_MS, retries, MAX_RETRIES);
        setTimeout(connectVnc, RETRY_DELAY_MS);
      } else {
        console.error("[vnc] Error:", err.message);
        ws.close();
      }
    });
  }

  connectVnc();

  ws.on("message", (data) => {
    if (vnc && vnc.writable) {
      vnc.write(Buffer.from(data));
    }
  });

  ws.on("close", () => {
    console.log("[ws] WebSocket closed");
    if (vnc) vnc.destroy();
  });

  ws.on("error", (err) => {
    console.error("[ws] Error:", err.message);
    if (vnc) vnc.destroy();
  });
});

httpServer.listen(WEB_PORT, () => {
  console.log();
  console.log("  noVNC viewer:  http://localhost:%d", WEB_PORT);
  console.log("  VNC backend:   %s:%d", VNC_HOST, VNC_PORT);
  console.log();
  console.log("  Start 86Box with:");
  console.log('    QT_QPA_PLATFORM=vnc:size=800x600:port=%d ./86Box --headless -P /path/to/vm', VNC_PORT);
  console.log();
});
