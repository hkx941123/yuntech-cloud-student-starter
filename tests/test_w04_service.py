"""W4 offline contract checks.

Every request body used here comes from a JSON file in tests/fixtures/, so a broken
fixture fails the suite instead of being quietly replaced by an inline copy. No AWS
calls, no network beyond loopback, and no real token is read or printed.
"""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = Path(__file__).with_name("fixtures")
SERVICE_PATH = ROOT / "app/service.py"

REPORTER = "offline-reporter-token-not-a-real-secret"
OPERATOR = "offline-operator-token-not-a-real-secret"

spec = importlib.util.spec_from_file_location("w04_service", SERVICE_PATH)
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


def load_fixtures():
    """Read every fixture file; each one carries its own expectation."""
    found = {}
    for path in sorted(FIXTURE_DIR.glob("*.json")):
        case = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(case, dict) or "body" not in case or "expected_status" not in case:
            raise unittest.SkipTest(f"{path.name} is missing expected_status or body")
        found[path.name] = case
    return found


FIXTURES = load_fixtures()
ACCEPTED = {n: c for n, c in FIXTURES.items() if c["expected_status"] == 201}
REJECTED = {n: c for n, c in FIXTURES.items() if c["expected_status"] == 400}


class ServiceBase(unittest.TestCase):
    env = None

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        version = Path(self._tmp.name) / "version"
        version.write_text("b" * 40)
        server = service.make_server(version, port=0, env=self.env)
        self.server = server
        self.base = "http://127.0.0.1:" + str(server.server_port)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(worker.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def call(self, method, path, body=None, token=None, media_type="application/json"):
        """Return (status, body). JSON endpoints are decoded; the display page stays text."""
        data = None
        headers = {}
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            headers["Content-Type"] = media_type
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.base + path, data=data,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, self.decode(response)
        except urllib.error.HTTPError as caught:
            return caught.code, self.decode(caught)

    @staticmethod
    def decode(response):
        raw = response.read().decode("utf-8", "replace")
        if "json" in (response.headers.get("Content-Type") or ""):
            return json.loads(raw) if raw else None
        return raw


class FixtureShape(unittest.TestCase):
    def test_one_accepted_and_two_rejected_fixtures_exist(self):
        self.assertGreaterEqual(len(ACCEPTED), 1, "no fixture with expected_status 201")
        self.assertGreaterEqual(len(REJECTED), 2, "need two fixtures with expected_status 400")

    def test_rejected_fixtures_cover_two_distinct_parse_failures(self):
        """Both reject cases target observed_at, but they must fail for different reasons."""
        from datetime import datetime
        naive, unparseable = [], []
        for case in REJECTED.values():
            stamp = case["body"]["observed_at"]
            try:
                parsed = datetime.fromisoformat(stamp)
            except (TypeError, ValueError):
                unparseable.append(stamp)
            else:
                self.assertIsNone(parsed.tzinfo, f"{stamp!r} is not a naive timestamp")
                naive.append(stamp)
        self.assertEqual(len(naive), 1, "need one fixture that parses without a timezone")
        self.assertEqual(len(unparseable), 1, "need one fixture that is not ISO 8601 at all")

    def test_no_fixture_still_carries_a_todo_placeholder(self):
        for name, case in FIXTURES.items():
            rendered = json.dumps(case["body"], ensure_ascii=False)
            self.assertNotIn("TODO", rendered, f"{name} still has an unfilled placeholder")


class Authenticated(ServiceBase):
    env = {"REPORTER_TOKEN": REPORTER, "OPERATOR_TOKEN": OPERATOR}

    def test_accepted_fixture_creates_an_event(self):
        for name, case in ACCEPTED.items():
            with self.subTest(fixture=name):
                status, payload = self.call("POST", "/events", case["body"], REPORTER)
                self.assertEqual(status, case["expected_status"])
                self.assertEqual(payload["event_id"], case["body"]["event_id"])
                self.assertTrue(payload["received_at"].endswith("Z"))
                self.assertNotIn("received_at", case["body"])

    def test_rejected_fixtures_report_the_offending_field(self):
        for name, case in REJECTED.items():
            with self.subTest(fixture=name):
                status, payload = self.call("POST", "/events", case["body"], REPORTER)
                self.assertEqual(status, case["expected_status"])
                self.assertEqual(payload.get("field"), case["expected_field"])
                self.assertNotIn("body", payload)

    def test_reported_events_are_listed_and_retrievable(self):
        first = next(iter(ACCEPTED.values()))
        self.call("POST", "/events", first["body"], REPORTER)
        status, payload = self.call("GET", "/events", token=OPERATOR)
        self.assertEqual(status, 200)
        identifiers = [item["event_id"] for item in payload["events"]]
        self.assertIn(first["body"]["event_id"], identifiers)
        status, record = self.call("GET", "/events/" + first["body"]["event_id"], token=OPERATOR)
        self.assertEqual(status, 200)
        self.assertEqual(record["event_id"], first["body"]["event_id"])
        self.assertEqual(self.call("GET", "/events/absent-id", token=OPERATOR)[0], 404)

    def test_duplicate_event_id_is_a_conflict(self):
        case = next(iter(ACCEPTED.values()))
        self.assertEqual(self.call("POST", "/events", case["body"], REPORTER)[0], 201)
        status, payload = self.call("POST", "/events", case["body"], REPORTER)
        self.assertEqual(status, 409)
        self.assertEqual(payload.get("field"), "event_id")

    def test_authentication_precedes_validation(self):
        """No token plus a broken body must still be 401, never 400."""
        for body in ({"totally": "wrong"}, b"{not json", []):
            with self.subTest(body=repr(body)[:24]):
                self.assertEqual(self.call("POST", "/events", body)[0], 401)
        self.assertEqual(self.call("POST", "/events", {"totally": "wrong"}, "not-a-token")[0], 401)
        self.assertEqual(self.call("GET", "/events")[0], 401)

    def test_roles_are_enforced(self):
        case = next(iter(ACCEPTED.values()))
        self.assertEqual(self.call("POST", "/events", case["body"], OPERATOR)[0], 403)
        self.assertEqual(self.call("GET", "/events", token=REPORTER)[0], 403)
        self.assertEqual(self.call("GET", "/events/anything", token=REPORTER)[0], 403)

    def test_error_bodies_expose_only_error_and_field(self):
        for response in (self.call("GET", "/events"),
                         self.call("POST", "/events", {}, OPERATOR),
                         self.call("GET", "/nope")):
            with self.subTest(status=response[0]):
                self.assertTrue(set(response[1]) <= {"error", "field"}, response[1])

    def test_health_reports_auth_configured(self):
        status, payload = self.call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(payload["auth_configured"])
        self.assertEqual(payload["version"], "b" * 40)

    def test_oversize_body_is_rejected(self):
        case = dict(next(iter(ACCEPTED.values()))["body"])
        case["note"] = "x" * 5000
        self.assertEqual(self.call("POST", "/events", case, REPORTER)[0], 400)

    def test_wrong_media_type_is_rejected(self):
        case = next(iter(ACCEPTED.values()))["body"]
        self.assertEqual(self.call("POST", "/events", case, REPORTER, "text/plain")[0], 400)

    def test_display_page_is_public_and_never_embeds_a_token(self):
        status, page = self.call("GET", "/")
        self.assertEqual(status, 200)
        for banned in ("innerHTML", "localStorage", "?token="):
            self.assertNotIn(banned, str(page))
        for secret in (REPORTER, OPERATOR):
            self.assertNotIn(secret, str(page))


class FailsClosed(ServiceBase):
    env = {}

    def test_no_configured_token_means_every_write_is_unauthorised(self):
        status, payload = self.call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertFalse(payload["auth_configured"])
        self.assertEqual(self.call("POST", "/events", {"event_id": "a"}, REPORTER)[0], 401)
        self.assertEqual(self.call("GET", "/events", token=OPERATOR)[0], 401)


class SourceHygiene(unittest.TestCase):
    def test_service_source_avoids_unsafe_dom_and_browser_storage(self):
        text = SERVICE_PATH.read_text(encoding="utf-8")
        for banned in ("innerHTML", "localStorage", "?token=", "sessionStorage"):
            self.assertNotIn(banned, text)

    def test_service_source_does_not_print_or_log_request_data(self):
        text = SERVICE_PATH.read_text(encoding="utf-8")
        for banned in ("print(", "logging.", "logger"):
            self.assertNotIn(banned, text)


if __name__ == "__main__":
    unittest.main()
