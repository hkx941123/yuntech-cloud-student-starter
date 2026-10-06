#!/usr/bin/env bash
# W4 deploy.sh：把「已 commit 的一個版本」部署到既有的那台主機，然後放上秘密檔並重啟。
#
# 四條規格（labs/04-web-api/README.md）：
#   1. 只部署已 commit 的版本：用 deploy/make-user-data.sh 產生安裝腳本（與 up.sh 同一份打包器）。
#   2. 經 SSH 在原本那台主機執行安裝腳本（-o StrictHostKeyChecking=accept-new），
#      再把 .local/app.env 經 SSH 的標準輸入放到 /etc/inspection/app.env（root、600），
#      然後再重啟一次 inspection。部署前先檢查本機 .local/app.env 是 600。
#   3. 結束時確認 /health 的 version 等於這次的 commit、auth_configured 是 true。
#   4. 執行前印出目標主機與 commit，等你輸入確認字串才繼續。
#
# 本腳本不建立、不修改、不刪除任何 AWS 資源；不改 SG、不碰 IAM、不用 --auto。
# 秘密只走 SSH 標準輸入，不出現在命令列參數、輸出或 user data 裡。
#
# 用法：
#   bash deploy/deploy.sh --dry-run          # 只做檢查與唯讀查詢，印出計畫後結束
#   bash deploy/deploy.sh                    # 真正部署（部署前會要求輸入確認字串）
#   bash deploy/deploy.sh --commit <sha>     # 部署指定的 commit（回滾用）
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
COMMIT=""
KEY="${HOME}/.ssh/w03-t1"
SSH_USER="ec2-user"
SECRET_FILE=".local/app.env"
DB_SECRET_FILE=".local/db.env"
RESOURCES=".local/resources.json"
CONF=".local/w03.conf"
HEALTH_TRIES=12
HEALTH_WAIT=3

stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --commit) [[ $# -ge 2 ]] || stop "--commit 需要一個 commit SHA"; COMMIT="$2"; shift 2 ;;
    --key) [[ $# -ge 2 ]] || stop "--key 需要一個路徑"; KEY="$2"; shift 2 ;;
    *) stop "未知參數：$1" ;;
  esac
done

# ---------------------------------------------------------------- 步驟 0：前置檢查
if [[ ! -f "$RESOURCES" ]]; then
  stop "找不到 $RESOURCES（個人資源清單）。不要憑記憶猜 instance ID。"
fi
if [[ ! -r "$KEY" ]]; then
  stop "找不到 SSH 私鑰 $KEY。它只留在你的 Codespace，不要交給任何人。"
fi
if [[ "$(stat -c '%a' "$KEY")" != "600" ]]; then
  stop "SSH 私鑰 $KEY 權限是 $(stat -c '%a' "$KEY")，必須先 chmod 600。"
fi
if git status --porcelain -- app/service.py deploy/nginx.conf | grep -q .; then
  git status --porcelain -- app/service.py deploy/nginx.conf >&2
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[注意] 打包的兩個檔有未提交異動：實際部署的是 commit 內容，不是工作區內容。"
  else
    stop "app/service.py 或 deploy/nginx.conf 有未提交異動。先 commit 再部署。"
  fi
fi
SECRET_MODE="不存在"
if [[ -f "$SECRET_FILE" ]]; then
  SECRET_MODE="$(stat -c '%a' "$SECRET_FILE")"
  if [[ "$SECRET_MODE" != "600" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      note "[注意] $SECRET_FILE 權限是 $SECRET_MODE，不是 600；真正部署時本腳本會停下。"
    else
      stop "$SECRET_FILE 權限是 $SECRET_MODE，必須先 chmod 600。"
    fi
  fi
else
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[注意] 還沒有 $SECRET_FILE。真正部署前請你自己用 umask 077 產生（權杖不要交給 Agent）。"
  else
    stop "找不到 $SECRET_FILE。請先在自己終端機產生權杖並 chmod 600。"
  fi
fi
if [[ ! -f "$DB_SECRET_FILE" ]]; then
  stop "找不到 $DB_SECRET_FILE。W5 部署需要資料庫設定。"
fi
DB_SECRET_MODE="$(stat -c '%a' "$DB_SECRET_FILE")"
if [[ "$DB_SECRET_MODE" != "600" ]]; then
  stop "$DB_SECRET_FILE 權限是 $DB_SECRET_MODE，必須先 chmod 600。"
fi
if [[ -z "$COMMIT" ]]; then
  COMMIT="$(git rev-parse --verify --end-of-options 'HEAD^{commit}')"
fi
COMMIT="$(git rev-parse --verify --end-of-options "$COMMIT^{commit}")"
SHORT="${COMMIT:0:7}"
INSTANCE_ID="$(python3 -c 'import json,pathlib,sys;print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["instance"]["id"])' "$RESOURCES")"
note "本機檢查完成：instance $INSTANCE_ID、commit $COMMIT、app secrets=$SECRET_MODE、DB secrets=$DB_SECRET_MODE"

# ---------------------------------------------------------------- 步驟 1：身分
note ""
note "== 身分核對 =="
bash scripts/verify-aws.sh || stop "身分核對未通過，不要繼續。"

# ---------------------------------------------------------------- 步驟 2：唯讀查主機
note ""
note "== 主機現況（唯讀） =="
SUMMARY="$(python3 - "$INSTANCE_ID" <<'PY' || stop "查詢主機失敗，沒有做任何變更。"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)
try:
    ctx = lab.context()
    found = lab.run_aws(["ec2", "describe-instances", "--instance-ids", sys.argv[1], "--query",
        "Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,"
        "PrivateIp:PrivateIpAddress,AZ:Placement.AvailabilityZone,Type:InstanceType,"
        "SGs:SecurityGroups[0].GroupId,Name:Tags[?Key=='Name']|[0].Value}"], ctx["region"])
    if not isinstance(found, dict):
        print("STOP: 找不到 instance " + sys.argv[1], file=sys.stderr)
        raise SystemExit(1)
    rules = lab.run_aws(["ec2", "describe-security-groups", "--group-ids", found["SGs"], "--query",
        "SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,"
        "CIDRs:IpRanges[].CidrIp}"], ctx["region"])
    print(json.dumps({"account_ending": ctx["account"][-4:], "region": ctx["region"],
                      "instance": found, "sg_rules": rules}))
except lab.LabError as exc:
    print("STOP: " + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
)"
field() {
  python3 -c '
import json, sys
node = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    node = node[part]
print(node)' "$1" <<<"$SUMMARY"
}
STATE="$(field instance.State)"
PUBLIC_IP="$(field instance.PublicIp)"
SG_ID="$(field instance.SGs)"
note "  instance $INSTANCE_ID  名稱 $(field instance.Name)  狀態 $STATE"
note "  公開位址 $PUBLIC_IP  私有位址 $(field instance.PrivateIp)  $(field instance.Type) / $(field instance.AZ)"
note "  security group $SG_ID"
[[ "$STATE" == "running" ]] || stop "主機狀態是 $STATE，不是 running。啟動主機是另一個動作，本腳本不代勞。"

# 檔案裡的位址若與 AWS 不同，以 AWS 為準並提示。
if [[ -f "$CONF" ]]; then
  FILE_IP="$(sed -n 's/^PUBLIC_IP=//p' "$CONF")"
  if [[ -n "$FILE_IP" && "$FILE_IP" != "$PUBLIC_IP" ]]; then
    note "  [注意] $CONF 記的位址是 $FILE_IP，AWS 現況是 $PUBLIC_IP；以 AWS 為準，請更新紀錄。"
  fi
fi

# ---------------------------------------------------------------- 步驟 3：出口 /32 與 SG
note ""
note "== 來源 /32 核對 =="
EGRESS="$(curl -4 -sS --max-time 8 https://checkip.amazonaws.com)" || stop "查不到本機出口 IP，未做任何變更。"
ALLOWED_80="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(c for r in d["sg_rules"]
                if r["Proto"] == "tcp" and r["From"] == 80 and r["To"] == 80
                for c in r["CIDRs"]))' <<<"$SUMMARY")"
note "  本機出口 $EGRESS；SG $SG_ID 放行 80 的來源：$ALLOWED_80"
if [[ ",$ALLOWED_80," != *",$EGRESS/32,"* ]]; then
  stop "SG 只放行 $ALLOWED_80，本機出口是 $EGRESS/32。本腳本不改 SG；請把舊/新 /32 交給審查者核准後再處理。"
fi

# ---------------------------------------------------------------- 步驟 4：印出計畫並確認
PACKAGE=".local/user-data-$SHORT.sh"
note ""
note "== 部署計畫 =="
note "  目標主機  : $INSTANCE_ID（$PUBLIC_IP）"
note "  來源 /32  : $EGRESS/32（與 SG 一致，不需修改）"
note "  部署版本  : $COMMIT"
note "  安裝腳本  : $PACKAGE（只含 app/service.py、deploy/nginx.conf、app/version）"
note "  主機上會被覆寫：/opt/inspection/**、/etc/nginx/nginx.conf、"
note "                 /etc/systemd/system/inspection.service、/etc/inspection/app.env"
note "  會將 app.env + db.env 經 SSH 標準輸入合併寫入主機（root:600）"
note "  會重啟 inspection：W4 記憶體事件會清空；RDS 事件不受影響"
note "  AWS 資源  : 建立 0、變更 0、刪除 0；SG 與 IAM 不動"
note "  回滾方式  : bash deploy/deploy.sh --commit <前一個 commit>"

if [[ $DRY_RUN -eq 1 ]]; then
  note ""
  note "DRY RUN：到此為止，沒有連線到主機、沒有部署、沒有改任何東西。"
  exit 0
fi

[[ -t 0 ]] || stop "需要互動式終端機輸入確認字串。請你在自己的終端機執行本指令。"
TOKEN="DEPLOY-$SHORT"
printf '\n輸入 %s 繼續部署（其他任何輸入都會中止）: ' "$TOKEN"
read -r ANSWER
[[ "$ANSWER" == "$TOKEN" ]] || stop "已中止，沒有做任何變更。"

# ---------------------------------------------------------------- 步驟 5：打包
note ""
rm -f "$PACKAGE"
bash deploy/make-user-data.sh "$COMMIT" "$PACKAGE" || stop "打包失敗，沒有連線到主機。"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)

# ---------------------------------------------------------------- 步驟 6：遠端執行安裝腳本
note ""
note "== 遠端安裝（SSH，資料通道） =="
ssh "${SSH_OPTS[@]}" "$SSH_USER@$PUBLIC_IP" 'sudo -n bash -s' <"$PACKAGE" \
  || stop "安裝腳本執行失敗。服務可能仍是舊版；修正後重跑本指令即可（冪等）。"

# ---------------------------------------------------------------- 步驟 7：秘密檔 + 重啟
note ""
note "== 放置秘密檔並重啟服務 =="
{
  cat "$SECRET_FILE"
  printf '\n'
  cat "$DB_SECRET_FILE"
} | ssh "${SSH_OPTS[@]}" "$SSH_USER@$PUBLIC_IP" \
  'sudo -n install -d -m 755 /etc/inspection &&
   sudo -n tee /etc/inspection/app.env >/dev/null &&
   sudo -n chmod 600 /etc/inspection/app.env &&
   sudo -n chown root:root /etc/inspection/app.env &&
   sudo -n systemctl restart inspection' \
  || stop "秘密檔或重啟失敗。請檢查 /etc/inspection/app.env 是否存在且為 root 600。"

# ---------------------------------------------------------------- 步驟 8：驗證
note ""
note "== 驗證 /health =="
BODY=""
for attempt in $(seq 1 "$HEALTH_TRIES"); do
  sleep "$HEALTH_WAIT"
  BODY="$(curl --noproxy '*' -4 -sS --max-time 8 "http://$PUBLIC_IP/health" 2>/dev/null || true)"
  VERSION="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.argv[1]).get("version", ""))
except ValueError:
    print("")' "$BODY" 2>/dev/null || true)"
  if [[ "$VERSION" == "$COMMIT" ]]; then break; fi
  note "  第 $attempt 次：version=${VERSION:-（無回應）}"
done
note "  /health 回應：$BODY"
python3 -c '
import json, sys
try:
    body = json.loads(sys.argv[1])
except ValueError:
    raise SystemExit("STOP: /health 沒有回應或不是 JSON，未通過驗證。")
if body.get("version") != sys.argv[2]:
    raise SystemExit("STOP: version 不是這次的 commit（主機上目前是 " + str(body.get("version")) + "）。")
if body.get("auth_configured") is not True:
    raise SystemExit("STOP: auth_configured 不是 true，服務沒有讀到 /etc/inspection/app.env。")
if body.get("db_configured") is not True:
    raise SystemExit("STOP: db_configured 不是 true，服務沒有讀到 /etc/inspection/app.env 的資料庫設定。")
print("  version 等於 " + sys.argv[2])
print("  auth_configured = true")
print("  db_configured = true")
' "$BODY" "$COMMIT" || stop "驗證未通過；主機上目前是什麼版本請自行用 /health 確認，不要猜。"

note ""
note "部署完成：$COMMIT → $PUBLIC_IP（version、auth_configured、db_configured 都已核對）"
note "回滾：bash deploy/deploy.sh --commit <前一個 commit>"
