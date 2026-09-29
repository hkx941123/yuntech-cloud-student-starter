#!/usr/bin/env python3
"""拒絕矩陣：一次跑完 7 列，比對預期與實際。

輸出格式照 reports/W04_繳交範本.md 第 2 段的要求：
開頭先印 /health 的 version，接著每一列印編號、說明、預期、實際狀態碼與服務回應的本文。
回應本文不會包含權杖——服務的錯誤回應只有 error 與 field 兩欄，成功回應只有事件欄位。

兩種模式：

    # 離線自我測試（預設）：在本機 127.0.0.1 起服務，用合成權杖，不碰 AWS
    python3 tests/rejection_matrix.py

    # 指向已部署的主機：權杖由你自己在終端機匯出成環境變數，腳本不讀秘密檔、不印權杖
    set -a; source .local/app.env; set +a
    python3 tests/rejection_matrix.py --base-url http://<主機位址>

事件本文取自 tests/fixtures/，所以矩陣跑的內容就是你在 T2 寫的那幾筆。
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile
import threading
import urllib.error
import urllib.request

TESTS_DIR = Path(__file__).resolve().parent
ROOT = TESTS_DIR.parent
SERVICE_PATH = ROOT / "app/service.py"
FIXTURES = TESTS_DIR / "fixtures"

# 離線模式專用的合成權杖：不是任何人的真實權杖，也不會被部署到主機。
LOCAL_REPORTER = "local-dry-run-reporter-token-not-a-secret"
LOCAL_OPERATOR = "local-dry-run-operator-token-not-a-secret"

BODY_LIMIT = 1000

ROW_LABELS = {
    1: "reporter 送一筆合法事件",
    2: "同上，不帶權杖",
    3: "operator 權杖送事件",
    4: "reporter，observed_at 沒有時區",
    5: "reporter，再送一次 #1 的 event_id",
    6: "reporter 權杖讀清單",
    7: "operator 權杖讀清單且含 #1",
}


def load_fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def start_local_service():
    """在本機隨機埠起一份服務，回傳 (base_url, 伺服器, 暫存目錄)。"""
    spec = importlib.util.spec_from_file_location("matrix_service", SERVICE_PATH)
    service = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(service)
    workspace = tempfile.TemporaryDirectory()
    version = Path(workspace.name) / "version"
    version.write_text("0" * 40)
    server = service.make_server(
        version, port=0,
        env={"REPORTER_TOKEN": LOCAL_REPORTER, "OPERATOR_TOKEN": LOCAL_OPERATOR})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return "http://127.0.0.1:" + str(server.server_port), server, workspace


def call(base, method, path, body=None, token=None):
    """回傳 (status, 已解析的回應)。權杖只放標頭，不放網址。"""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read().decode("utf-8", "replace") or "null")
    except urllib.error.HTTPError as caught:
        return caught.code, json.loads(caught.read().decode("utf-8", "replace") or "null")


def render(payload):
    """把回應本文壓成單行 JSON；不印權杖（服務本來就不回顯）。"""
    text = json.dumps(payload, ensure_ascii=False)
    return text if len(text) <= BODY_LIMIT else text[:BODY_LIMIT] + "…（已截斷）"


def run_matrix(base, reporter, operator, event_id, id_was_fixed):
    """依序跑 7 列，回傳 [(編號, 預期, 實際, 是否通過, 備註, 回應本文), ...]。"""
    good = dict(load_fixture("accepted.json")["body"], event_id=event_id)
    naive = load_fixture("rejected-observed-at-naive.json")["body"]
    results = []

    def record(number, expected, actual, payload=None, note=""):
        results.append((number, expected, actual, actual == expected, note, payload))

    status, payload = call(base, "POST", "/events", good, reporter)
    if id_was_fixed and status == 409:
        # 明確指定 --event-id 且主機上已有該筆：建立本來就該是衝突。
        record(1, 201, 409, payload, "此 event_id 先前已送出，#1 改記為衝突")
    else:
        record(1, 201, status, payload)

    status, payload = call(base, "POST", "/events", good)
    record(2, 401, status, payload)
    status, payload = call(base, "POST", "/events", good, operator)
    record(3, 403, status, payload)
    status, payload = call(base, "POST", "/events", naive, reporter)
    record(4, 400, status, payload)
    status, payload = call(base, "POST", "/events", good, reporter)
    record(5, 409, status, payload)
    status, payload = call(base, "GET", "/events", None, reporter)
    record(6, 403, status, payload)

    status, payload = call(base, "GET", "/events", None, operator)
    identifiers = []
    if isinstance(payload, dict):
        identifiers = [item.get("event_id") for item in payload.get("events", [])]
    record(7, 200, status, payload,
           "" if event_id in identifiers else "清單查得到，但沒有 #1 的 event_id")
    return results


def main():
    parser = argparse.ArgumentParser(description="拒絕矩陣 7 列一次跑完")
    parser.add_argument("--base-url", help="已部署主機的基底網址；省略則跑本機離線自我測試")
    parser.add_argument("--event-id", help="第 1 列使用的 event_id；省略則每次執行產生新的")
    args = parser.parse_args()

    server = workspace = None
    if args.base_url:
        reporter = (os.environ.get("REPORTER_TOKEN") or "").strip()
        operator = (os.environ.get("OPERATOR_TOKEN") or "").strip()
        if not reporter or not operator:
            print("缺少 REPORTER_TOKEN 或 OPERATOR_TOKEN 環境變數。\n"
                  "請你自己在終端機匯出，不要把權杖寫進命令列參數，也不要交給 Agent：\n"
                  "  set -a; source .local/app.env; set +a", file=sys.stderr)
            return 2
        base = args.base_url.rstrip("/")
        print("目標：" + base)
    else:
        reporter, operator = LOCAL_REPORTER, LOCAL_OPERATOR
        base, server, workspace = start_local_service()
        print("離線自我測試：本機服務，未呼叫 AWS")

    fixed = bool(args.event_id)
    seed = load_fixture("accepted.json")["body"]["event_id"]
    event_id = args.event_id or seed + "-" + secrets.token_hex(4)

    # 繳交範本要求輸出開頭就有 version。
    health_status, health = call(base, "GET", "/health")
    print("服務版本（/health，HTTP {}）：{}".format(
        health_status, health.get("version", "（無）") if isinstance(health, dict) else "（無）"))
    print("auth_configured：{}".format(
        health.get("auth_configured") if isinstance(health, dict) else "（無）"))
    print("第 1 列 event_id：" + event_id)
    print()
    try:
        results = run_matrix(base, reporter, operator, event_id, fixed)
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        if workspace is not None:
            workspace.cleanup()

    for number, expected, actual, passed, note, payload in results:
        print("#{} {}".format(number, ROW_LABELS[number]))
        print("   預期 {}　實際 {}　{}".format(expected, actual, "PASS" if passed else "FAIL"))
        print("   回應 " + render(payload))
        if note:
            print("   備註 " + note)
    failures = [row[0] for row in results if not row[3]]
    print()
    print("通過 {ok}/{total}".format(ok=len(results) - len(failures), total=len(results))
          + ("，失敗列：" + ", ".join(str(n) for n in failures) if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
