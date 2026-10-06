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
import logging
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
DATABASE_FIELDS = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
DATABASE_CA_ENV = "DB_CA_CERT"
DATABASE_CA_DEFAULT = "/etc/inspection/rds-ca.pem"
logger = logging.getLogger("inspection")


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


def _database_settings(source):
    values = {name: (source.get(name) or "").strip() for name in DATABASE_FIELDS}
    ca_cert = (source.get(DATABASE_CA_ENV) or DATABASE_CA_DEFAULT).strip()
    if not all(values.values()) or not Path(ca_cert).is_file():
        return None
    try:
        port = int(source.get("DB_PORT") or "5432")
    except ValueError:
        return None
    if not 1 <= port <= 65535:
        return None
    values.update({"ca_cert": ca_cert, "port": port})
    return values


def _connect_database(settings):
    import psycopg2

    return psycopg2.connect(
        host=settings["DB_HOST"],
        port=settings["port"],
        dbname=settings["DB_NAME"],
        user=settings["DB_USER"],
        password=settings["DB_PASSWORD"],
        sslmode="verify-full",
        sslrootcert=settings["ca_cert"],
        connect_timeout=5,
    )


def _db_cursor(settings, operation):
    connection = _connect_database(settings)
    try:
        cursor = connection.cursor()
        try:
            result = operation(cursor)
            connection.commit()
            return result
        finally:
            cursor.close()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _ensure_events_table(settings):
    def create(cursor):
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                event_id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                event_type TEXT NOT NULL,
                note TEXT,
                received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

    _db_cursor(settings, create)


def _db_record(row):
    record = {
        "event_id": row[0],
        "device_id": row[1],
        "observed_at": row[2],
        "type": row[3],
        "received_at": row[5].astimezone(timezone.utc).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z"),
    }
    if row[4] is not None:
        record["note"] = row[4]
    return record


def _db_list_events(settings):
    def select(cursor):
        cursor.execute(
            """
            SELECT event_id, device_id, observed_at, event_type, note, received_at
            FROM events ORDER BY received_at DESC, event_id LIMIT %s
            """,
            (LIST_LIMIT,),
        )
        return [_db_record(row) for row in cursor.fetchall()]

    return _db_cursor(settings, select)


def _db_get_event(settings, event_id):
    def select(cursor):
        cursor.execute(
            """
            SELECT event_id, device_id, observed_at, event_type, note, received_at
            FROM events WHERE event_id = %s
            """,
            (event_id,),
        )
        row = cursor.fetchone()
        return _db_record(row) if row else None

    return _db_cursor(settings, select)


def _db_create_event(settings, payload):
    def create(cursor):
        cursor.execute(
            """
            INSERT INTO events (event_id, device_id, observed_at, event_type, note)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (event_id) DO NOTHING
            RETURNING event_id, device_id, observed_at, event_type, note, received_at
            """,
            (
                payload["event_id"],
                payload["device_id"],
                payload["observed_at"],
                payload["type"],
                payload.get("note"),
            ),
        )
        inserted = cursor.fetchone()
        if inserted:
            return 201, _db_record(inserted)

        cursor.execute(
            """
            SELECT event_id, device_id, observed_at, event_type, note, received_at
            FROM events WHERE event_id = %s
            """,
            (payload["event_id"],),
        )
        existing = cursor.fetchone()
        if not existing:
            raise RuntimeError("conflicting event disappeared before it could be read")
        same_content = (
            existing[1] == payload["device_id"]
            and existing[2] == payload["observed_at"]
            and existing[3] == payload["type"]
            and existing[4] == payload.get("note")
        )
        if same_content:
            return 200, _db_record(existing)
        return 409, {"error": "duplicate_event_id", "field": "event_id"}

    return _db_cursor(settings, create)


def _database_failure(operation, exc):
    logger.warning("%s failed (%s)", operation, type(exc).__name__)
    return {"error": "database_unavailable", "field": None}


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
    database_settings = _database_settings(source)
    database_configured = database_settings is not None
    database_ready = False
    database_lock = threading.Lock()

    lock = threading.Lock()
    events = {}

    class Handler(BaseHTTPRequestHandler):
        def ensure_database(self):
            nonlocal database_ready
            if database_ready:
                return
            with database_lock:
                if not database_ready:
                    _ensure_events_table(database_settings)
                    database_ready = True

        def send_database_error(self, operation, exc):
            self.send_json(503, _database_failure(operation, exc))

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
                                     "auth_configured": auth_configured,
                                     "db_configured": database_configured})
                return
            if path == "/":
                self.send_page(200, _list_page())
                return
            if path == "/events":
                if self.require_role("operator") is None:
                    return
                if database_configured:
                    try:
                        self.ensure_database()
                        items = _db_list_events(database_settings)
                    except Exception as exc:
                        self.send_database_error("database list", exc)
                        return
                else:
                    with lock:
                        items = list(events.values())[-LIST_LIMIT:]
                self.send_json(200, {"events": items, "count": len(items)})
                return
            match = EVENT_PATH_RE.fullmatch(path)
            if match:
                if self.require_role("operator") is None:
                    return
                event_id = unquote(match.group(1))
                if database_configured:
                    try:
                        self.ensure_database()
                        record = _db_get_event(database_settings, event_id)
                    except Exception as exc:
                        self.send_database_error("database get", exc)
                        return
                else:
                    with lock:
                        record = events.get(event_id)
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
            if database_configured:
                try:
                    self.ensure_database()
                    status, record = _db_create_event(database_settings, payload)
                except Exception as exc:
                    self.send_database_error("database write", exc)
                    return
                self.send_json(status, record)
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
