#!/usr/bin/env python3
"""Minimal launcher webapp: one button, launches the AgenticPets Swift app."""
import http.server
import os
import subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, ".build", "debug", "AgenticPets")

INDEX_HTML = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Agentic Pets Launcher</title>
<style>
  body { font-family: -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #111; }
  button { font-size: 24px; padding: 20px 40px; border-radius: 12px; border: none; cursor: pointer; background: #4f8cff; color: white; }
  button:active { background: #2d6be0; }
  #status { color: #ccc; margin-top: 16px; font-family: monospace; text-align: center; }
</style>
</head>
<body>
<div>
  <div style="text-align:center">
    <button onclick="launch()">Launch Pet</button>
  </div>
  <div id="status"></div>
</div>
<script>
async function launch() {
  const status = document.getElementById('status');
  status.textContent = 'Launching...';
  try {
    const res = await fetch('/launch', { method: 'POST' });
    const text = await res.text();
    status.textContent = res.ok ? 'Pet launched!' : ('Error: ' + text);
  } catch (e) {
    status.textContent = 'Error: ' + e;
  }
}
</script>
</body>
</html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = INDEX_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/launch":
            if not os.path.exists(BINARY):
                self._respond(500, "Binary not found. Run `swift build` first.")
                return
            try:
                subprocess.Popen([BINARY], cwd=REPO_ROOT)
                self._respond(200, "launched")
            except Exception as e:
                self._respond(500, str(e))
        else:
            self.send_response(404)
            self.end_headers()

    def _respond(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # keep it quiet

if __name__ == "__main__":
    port = 8765
    print(f"Agentic Pets launcher running at http://localhost:{port}")
    http.server.HTTPServer(("localhost", port), Handler).serve_forever()
