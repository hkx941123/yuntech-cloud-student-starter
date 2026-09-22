"""Offline public-contract checks; no AWS calls or classroom answers."""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("w03_service", ROOT / "app/service.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceContract(unittest.TestCase):
    def test_health_version_and_unknown_route(self):
        with tempfile.TemporaryDirectory() as td:
            version = Path(td) / "version"
            version.write_text("a" * 40)
            server = service.make_server(version, port=0)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                self.assertEqual(server.server_address[0], "127.0.0.1")
                base = "http://127.0.0.1:" + str(server.server_port)
                with urllib.request.urlopen(base + "/health") as response:
                    result = json.load(response)
                    self.assertEqual(response.status, 200)
                    self.assertEqual(result["version"], "a" * 40)
                    self.assertEqual(result["service"], "inspection")
                    self.assertEqual(result["status"], "ok")
                    self.assertTrue(result["started_at"].endswith("Z"))
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(base + "/unknown")
                self.assertEqual(caught.exception.code, 404)
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=2)

    def test_invalid_deployment_version_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            version = Path(td) / "version"
            version.write_text("uncommitted")
            with self.assertRaises(ValueError):
                service.make_server(version, port=0)
