#!/usr/bin/env python3
"""Run the W5 persistence/idempotency matrix against the deployed EC2 host."""
import importlib.util
import json
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / ".local/resources.json"
APP_ENV = ROOT / ".local/app.env"
SSH_KEY = Path.home() / ".ssh/w03-t1"
SSH_USER = "ec2-user"
opener = build_opener(ProxyHandler({}))


def stop(message):
    print("STOP: " + message, file=sys.stderr)
    raise SystemExit(1)


def read_env_file(path, required):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key.strip()] = value
    missing = [key for key in required if not values.get(key)]
    if missing:
        stop(path.name + " 缺少必要欄位：" + ", ".join(missing))
    return values


def request(base, method, path, payload=None, token=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(base + path, data=data, headers=headers, method=method)
    try:
        response = opener.open(req, timeout=10)
    except HTTPError as error:
        response = error
    except URLError as error:
        raise RuntimeError("HTTP request failed (" + type(error.reason).__name__ + ")") from None
    with response:
        raw = response.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        return response.status, body


def render(body):
    return json.dumps(body, ensure_ascii=False, separators=(",", ":"))


def print_http_row(number, label, expected, status, body):
    print(f"{number} {label}: HTTP {status} (預期 {expected}) body={render(body)}")
    return status == expected


def ssh_run(ip, script):
    command = [
        "ssh", "-i", str(SSH_KEY), "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        SSH_USER + "@" + ip, "sudo -n bash -s",
    ]
    try:
        result = subprocess.run(command, input=script, text=True, capture_output=True,
                                check=True, timeout=45)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        raise RuntimeError("SSH operation failed (" + type(error).__name__ + ")") from None
    return result.stdout.strip()


def current_host_ip(instance_id, expected_course, expected_owner):
    spec = importlib.util.spec_from_file_location("lab", ROOT / "scripts/lab.py")
    lab = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lab)
    try:
        subprocess.run(
            ["bash", str(ROOT / "scripts/verify-aws.sh")],
            capture_output=True,
            text=True,
            check=True,
            timeout=90,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        raise RuntimeError("Learner Lab identity check failed; no matrix actions were run.") from None
    try:
        context = lab.context()
    except lab.LabError as error:
        raise RuntimeError(str(error)) from None
    try:
        host = lab.run_aws(
            [
                "ec2", "describe-instances", "--instance-ids", instance_id,
                "--query",
                "Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,Tags:Tags}",
            ],
            context["region"],
            env=lab.clean_env(context["region"]),
        )
    except lab.LabError as error:
        raise RuntimeError(str(error)) from None
    if not isinstance(host, dict) or host.get("State") != "running":
        stop("資源清單中的 EC2 不是 running；未執行矩陣。")
    tags = {item["Key"]: item["Value"] for item in host.get("Tags", [])}
    if tags.get("course") != expected_course or tags.get("owner") != expected_owner:
        stop("EC2 擁有權標籤不符；未執行矩陣。")
    ip = host.get("PublicIp")
    if not isinstance(ip, str) or not re.fullmatch(r"[0-9.]+", ip):
        stop("EC2 沒有有效的目前 Public IPv4；未執行矩陣。")
    return ip


def main():
    if not RESOURCES.is_file() or not APP_ENV.is_file():
        stop("需要 .local/resources.json 和 .local/app.env。")
    if not SSH_KEY.is_file():
        stop("找不到 SSH 私鑰 " + str(SSH_KEY) + "。")
    if stat.S_IMODE(SSH_KEY.stat().st_mode) != 0o600:
        stop("SSH 私鑰權限必須是 600。")

    try:
        resources = json.loads(RESOURCES.read_text(encoding="utf-8"))
        instance_id = resources["instance"]["id"]
        rds_identifier = resources["w05"]["rds"]["identifier"]
        w03_config = ROOT / ".local/w03.conf"
        config = {}
        for line in w03_config.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
        expected_course = config.get("COURSE", "yuntech-115-1")
        expected_owner = config["OWNER"]
    except (OSError, ValueError, KeyError, TypeError):
        stop("資源清單或 W3 設定缺少 instance ID／擁有權資訊。")
    try:
        ip = current_host_ip(instance_id, expected_course, expected_owner)
    except RuntimeError as error:
        stop(str(error))

    credentials = read_env_file(APP_ENV, ("REPORTER_TOKEN", "OPERATOR_TOKEN"))
    reporter = credentials["REPORTER_TOKEN"]
    operator = credentials["OPERATOR_TOKEN"]
    event_id = "w5-t3-" + secrets.token_hex(8)
    payload = {
        "event_id": event_id,
        "device_id": "w5-t3-matrix",
        "observed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "type": "test",
        "note": "W5 T3 idempotency matrix",
    }

    print("目標：EC2 " + instance_id + "（目前 IP " + ip + "）；RDS " + rds_identifier + " 的 inspection.events", file=sys.stderr)
    print("計畫：事件 " + event_id + "；送入新事件、原樣重送、改 note 重送、重啟 inspection、查 API 與 EC2 psql。", file=sys.stderr)
    print("影響：AWS 資源建立／變更／刪除均為 0，無新增費用或網路暴露；會在 RDS 保留這列測試事件，並重啟該 EC2 的 inspection。", file=sys.stderr)
    print("回復：服務若未恢復，使用 deploy/deploy.sh 部署核准版本；測試事件是持久化證據，不會由腳本刪除。", file=sys.stderr)
    if not sys.stdin.isatty():
        stop("需在互動式終端機執行並確認。")
    print("輸入 T3-MATRIX 繼續：", end="", file=sys.stderr, flush=True)
    if input().strip() != "T3-MATRIX":
        stop("已取消，沒有送出測試事件或重啟服務。")

    try:
        status, health = request("http://" + ip, "GET", "/health")
    except RuntimeError as error:
        stop(str(error))
    if status != 200 or not isinstance(health, dict):
        stop("/health 沒有回傳有效的 HTTP 200 JSON。")
    version = health.get("version")
    db_configured = health.get("db_configured")
    print("version=" + str(version))
    print("db_configured=" + str(db_configured).lower())
    if not isinstance(version, str) or not re.fullmatch(r"[0-9a-f]{40}", version):
        stop("/health 的 version 格式無效。")
    if db_configured is not True:
        stop("db_configured 不是 true；沒有送出測試事件。")

    good = True
    try:
        status1, body1 = request("http://" + ip, "POST", "/events", payload, reporter)
        good &= print_http_row(1, "新事件", 201, status1, body1)
        status2, body2 = request("http://" + ip, "POST", "/events", payload, reporter)
        good &= print_http_row(2, "相同內容重送", 200, status2, body2)
        changed = dict(payload, note="W5 T3 changed note")
        status3, body3 = request("http://" + ip, "POST", "/events", changed, reporter)
        good &= print_http_row(3, "相同 ID、不同 note", 409, status3, body3)

        ssh_run(ip, "systemctl restart inspection\n")
        for _ in range(15):
            try:
                ready_status, ready_body = request("http://" + ip, "GET", "/health")
            except RuntimeError:
                time.sleep(2)
                continue
            if (
                ready_status == 200
                and isinstance(ready_body, dict)
                and ready_body.get("version") == version
                and ready_body.get("db_configured") is True
            ):
                break
            time.sleep(2)
        else:
            stop("重啟後服務未在期限內回報相同 version 與 db_configured=true。")
        status4, body4 = request("http://" + ip, "GET", "/events/" + event_id, token=operator)
        good &= print_http_row(4, "重啟後查詢 #1", 200, status4, body4)

        psql_script = (
            "set -a\n"
            ". /etc/inspection/app.env\n"
            "set +a\n"
            'PGPASSWORD="$DB_PASSWORD" psql '
            '"host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER '
            'sslmode=verify-full sslrootcert=/etc/inspection/rds-ca.pem" '
            '-X -A -t -v event_id=' + event_id + " <<'SQL'\n"
            "SELECT count(*) FROM events WHERE event_id = :'event_id';\n"
            "SQL\n"
        )
        count = ssh_run(ip, psql_script)
        if not re.fullmatch(r"[0-9]+", count):
            stop("EC2 psql 沒有回傳純筆數；沒有印出遠端錯誤內容。")
        print(f"5 EC2 psql count={count} (預期 1)")
        good &= count == "1"
    except RuntimeError as error:
        stop(str(error))

    if not good:
        stop("至少一列未符合預期；以上列印的是實際觀測結果。")
    print("矩陣完成：五列皆符合預期。")


if __name__ == "__main__":
    main()
