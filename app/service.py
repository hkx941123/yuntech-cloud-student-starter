#!/usr/bin/env python3
"""W3 supplied inspection-service prototype; extend routes in later Sprints."""
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re


def make_server(version_file, port=8080):
    version = Path(version_file).read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", version):
        raise ValueError("version must contain the deployed 40-character Git commit SHA")
    started = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def do_GET(self):
            ok = self.path == "/health"
            body = {"status": "ok", "service": "inspection", "version": version,
                    "started_at": started} if ok else {"error": "not_found"}
            data = json.dumps(body).encode("utf-8")
            self.send_response(200 if ok else 404)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):
            pass  # Never log request paths, bodies, headers or query strings.

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    make_server(Path(__file__).with_name("version")).serve_forever()
