#!/usr/bin/env python3
"""W3/W4 inspection-service prototype.

Contract order for POST /events is fixed and never reordered:
    401 authentication -> 403 authorization -> 400 validation -> 409 duplicate -> 201 created
Authentication runs before the request body is touched, so a caller without a valid
token always learns nothing about the field rules.

Secrets are read once at start-up. They are never logged, never echoed in an error
body and never placed in a URL. Error bodies carry only "error" and "field".
Events live in process memory and are lost when the service restarts.
"""
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import threading
from urllib.parse import unquote, urlsplit

MAX_BODY_BYTES = 4096
MAX_NOTE_CHARS = 200
LIST_LIMIT = 50
ALLOWED_FIELDS = frozenset({"event_id", "device_id", "observed_at", "type", "note"})
REQUIRED_FIELDS = ("event_id", "device_id", "observed_at", "type")
EVENT_TYPES = frozenset({"status", "anomaly", "test"})
EVENT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
DEVICE_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
EVENT_PATH_RE = re.compile(r"/events/([^/]+)")


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _is_timestamp_with_timezone(value):
    """ISO 8601 that carries an explicit offset. A naive local time is rejected."""
    if not isinstance(value, str):
        return False
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return False
    return parsed.tzinfo is not None


def _validate(payload):
    """Return (status, error_body) for the first contract violation, or None."""
    extra = sorted(set(payload) - ALLOWED_FIELDS)
    if extra:
        return 400, {"error": "unknown_field", "field": extra[0]}
    for name in REQUIRED_FIELDS:
        if name not in payload:
            return 400, {"error": "missing_field", "field": name}
    if not isinstance(payload["event_id"], str) or not EVENT_ID_RE.fullmatch(payload["event_id"]):
        return 400, {"error": "invalid_field", "field": "event_id"}
    if not isinstance(payload["device_id"], str) or not DEVICE_ID_RE.fullmatch(payload["device_id"]):
        return 400, {"error": "invalid_field", "field": "device_id"}
    if not _is_timestamp_with_timezone(payload["observed_at"]):
        return 400, {"error": "invalid_field", "field": "observed_at"}
    if not isinstance(payload["type"], str) or payload["type"] not in EVENT_TYPES:
        return 400, {"error": "invalid_field", "field": "type"}
    if "note" in payload:
        note = payload["note"]
        if not isinstance(note, str) or len(note) > MAX_NOTE_CHARS:
            return 400, {"error": "invalid_field", "field": "note"}
    return None


def _list_page():
    return """<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<title>巡檢事件</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
input { min-width: 22rem; }
pre { white-space: pre-wrap; word-break: break-all; background: #f5f5f5; padding: 1rem; }
</style>
</head>
<body>
<h1>巡檢事件</h1>
<p>貼上 operator 權杖後按「載入」。權杖只留在這個頁面的記憶體裡，不會寫進網址，也不會存進瀏覽器。</p>
<p><input id="token" type="password" autocomplete="off" aria-label="operator 權杖">
<button id="load" type="button">載入</button></p>
<p id="status" role="status"></p>
<pre id="out"></pre>
<script>
const tokenBox = document.getElementById("token");
const statusLine = document.getElementById("status");
const out = document.getElementById("out");

function show(fields) {
  const line = document.createElement("div");
  line.textContent = fields.join("  |  ");
  out.appendChild(line);
}

document.getElementById("load").addEventListener("click", async () => {
  out.textContent = "";
  statusLine.textContent = "";
  const offered = tokenBox.value;
  try {
    const response = await fetch("/events", {headers: {Authorization: "Bearer " + offered}});
    const data = await response.json();
    if (!response.ok) {
      statusLine.textContent = "HTTP " + response.status + " " + (data.error || "");
      return;
    }
    statusLine.textContent = "共 " + data.count + " 筆（最新 " + data.events.length + " 筆）";
    for (const item of data.events) {
      show([item.event_id, item.device_id, item.type,
            item.observed_at, item.received_at,
            item.note === undefined ? "" : item.note]);
    }
  } catch (problem) {
    statusLine.textContent = "無法連線：" + problem.message;
  }
});
</script>
</body>
</html>
"""


def make_server(version_file, port=8080, env=None):
    """Build the HTTP server.

    ``env`` defaults to the process environment. Tests pass a synthetic mapping so
    that no real secret is ever read, written or displayed.
    """
    version = Path(version_file).read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", version):
        raise ValueError("version must contain the deployed 40-character Git commit SHA")
    started = _now()

    source = os.environ if env is None else env
    reporter_token = (source.get("REPORTER_TOKEN") or "").strip()
    operator_token = (source.get("OPERATOR_TOKEN") or "").strip()
    auth_configured = bool(reporter_token) and bool(operator_token)

    lock = threading.Lock()
    events = {}

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def send_json(self, code, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def send_page(self, code, text):
            data = text.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def offered_role(self):
            """Return 'reporter', 'operator' or None. The header value is never logged."""
            header = self.headers.get("Authorization") or ""
            scheme, _, offered = header.partition(" ")
            if scheme.lower() != "bearer":
                return None
            offered = offered.strip()
            if not offered:
                return None
            # Compare as bytes: compare_digest rejects non-ASCII str with TypeError.
            probe = offered.encode("utf-8", "surrogatepass")
            if reporter_token and secrets.compare_digest(probe, reporter_token.encode("utf-8")):
                return "reporter"
            if operator_token and secrets.compare_digest(probe, operator_token.encode("utf-8")):
                return "operator"
            return None

        def require_role(self, wanted):
            """401 before 403; returns the role on success, else True once answered."""
            role = self.offered_role()
            if role is None:
                self.send_json(401, {"error": "unauthorized", "field": None})
                return None
            if role != wanted:
                self.send_json(403, {"error": "forbidden", "field": None})
                return None
            return role

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/health":
                self.send_json(200, {"status": "ok", "service": "inspection",
                                     "version": version, "started_at": started,
                                     "auth_configured": auth_configured})
                return
            if path == "/":
                self.send_page(200, _list_page())
                return
            if path == "/events":
                if self.require_role("operator") is None:
                    return
                with lock:
                    items = list(events.values())[-LIST_LIMIT:]
                self.send_json(200, {"events": items, "count": len(items)})
                return
            match = EVENT_PATH_RE.fullmatch(path)
            if match:
                if self.require_role("operator") is None:
                    return
                with lock:
                    record = events.get(unquote(match.group(1)))
                if record is None:
                    self.send_json(404, {"error": "not_found", "field": None})
                else:
                    self.send_json(200, record)
                return
            self.send_json(404, {"error": "not_found", "field": None})

        def do_POST(self):
            if urlsplit(self.path).path != "/events":
                self.send_json(404, {"error": "not_found", "field": None})
                return
            # 1. Authentication runs before the body is read or parsed.
            if self.require_role("reporter") is None:
                return
            # 2. A known token in the wrong role is forbidden, not merely unauthorised.
            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length) if raw_length is not None else -1
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY_BYTES:
                self.send_json(400, {"error": "invalid_body", "field": None})
                return
            media = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if media != "application/json":
                self.send_json(400, {"error": "unsupported_media_type", "field": None})
                return
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self.send_json(400, {"error": "invalid_json", "field": None})
                return
            if not isinstance(payload, dict):
                self.send_json(400, {"error": "invalid_json", "field": None})
                return
            # 3. Field validation.
            failure = _validate(payload)
            if failure is not None:
                self.send_json(*failure)
                return
            # 4 and 5. Duplicate detection and creation share one critical section.
            with lock:
                if payload["event_id"] in events:
                    duplicate = True
                else:
                    duplicate = False
                    record = dict(payload)
                    record["received_at"] = _now()
                    events[record["event_id"]] = record
            if duplicate:
                self.send_json(409, {"error": "duplicate_event_id", "field": "event_id"})
                return
            self.send_json(201, record)

        def log_message(self, fmt, *args):
            pass  # Never log request paths, bodies, headers, tokens or query strings.

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    make_server(Path(__file__).with_name("version")).serve_forever()
