#!/usr/bin/env bash
# deploy/up.sh：從本 repo 的一個 commit 建立一台巡檢主機（W3 T2/T4 規格）。
#
# 範圍（不超出 W3 README 的範圍）：1 個 SG、1 個匯入的 key pair、1 台 AL2023 t3.micro。
# 不建 VPC、不建 NAT、不建 EIP、不動 IAM；SG 只放行本機出口 /32 的 TCP 22 與 80。
#
# 所有 AWS 指令都經過 scripts/lab.py 的 context()/run_aws()（固定 learnerlab profile、
# 清理過的環境變數），不在這支腳本裡自己組憑證。
#
# 用法：
#   bash deploy/up.sh --dry-run      # 只做唯讀查詢並印出將建立的清單，不建立任何資源
#   bash deploy/up.sh                # 真正建立（執行前要求輸入確認字串）
#   bash deploy/up.sh --commit <sha> # 指定要部署的 commit（預設 HEAD）
#   bash deploy/up.sh --replace      # 允許在已有未 terminated 主機時建立（需自己承擔同時兩台的費用）
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
REPLACE=0
COMMIT="HEAD"
AMI=""
SUBNET=""
SG_NAME=""
KEY_NAME=""
CONF=".local/w03.conf"
RESOURCES=".local/resources.json"
EARLY_WAIT=10
STATUS_TRIES=30
STATUS_WAIT=10
HEALTH_TRIES=30
HEALTH_WAIT=10

stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --replace) REPLACE=1; shift ;;
    --commit) [[ $# -ge 2 ]] || stop "--commit 需要一個值"; COMMIT="$2"; shift 2 ;;
    --ami) [[ $# -ge 2 ]] || stop "--ami 需要一個值"; AMI="$2"; shift 2 ;;
    --subnet) [[ $# -ge 2 ]] || stop "--subnet 需要一個值"; SUBNET="$2"; shift 2 ;;
    --sg-name) [[ $# -ge 2 ]] || stop "--sg-name 需要一個值"; SG_NAME="$2"; shift 2 ;;
    --key-name) [[ $# -ge 2 ]] || stop "--key-name 需要一個值"; KEY_NAME="$2"; shift 2 ;;
    *) stop "未知參數：$1" ;;
  esac
done

# ------------------------------------------------------------------ 讀取 .local 設定
conf_get() { [[ -f "$CONF" ]] || return 1; sed -n "s/^$1=//p" "$CONF" | head -n 1; }
COURSE="$(conf_get COURSE || true)"; COURSE="${COURSE:-yuntech-115-1}"
WEEK="$(conf_get WEEK || true)"; WEEK="${WEEK:-w03}"
GROUP="$(conf_get GROUP || true)"
OWNER="$(conf_get OWNER || true)"
[[ -n "$SUBNET" ]] || SUBNET="$(conf_get SUBNET || true)"
[[ -n "$AMI" ]] || AMI="$(conf_get AMI || true)"
[[ -n "$SG_NAME" ]] || SG_NAME="$(conf_get SG_NAME || true)"
[[ -n "$KEY_NAME" ]] || KEY_NAME="$(conf_get KEY_NAME || true)"
PUBKEY="${HOME}/.ssh/${KEY_NAME}.pub"
PACKAGE=".local/w03-user-data.sh"

[[ -n "$SUBNET" ]] || stop "沒有子網資訊：請用 --subnet 或在 $CONF 設定 SUBNET。"
[[ -n "$AMI" ]] || stop "沒有 AMI 資訊：請用 --ami 或在 $CONF 設定 AMI。"
[[ -n "$SG_NAME" ]] || stop "沒有 SG 名稱：請用 --sg-name 或在 $CONF 設定 SG_NAME。"
[[ -n "$KEY_NAME" ]] || stop "沒有 key pair 名稱：請用 --key-name 或在 $CONF 設定 KEY_NAME。"
[[ -r "$PUBKEY" ]] || stop "找不到公開金鑰 $PUBKEY（.pub）。私鑰留在 Codespace，不進 AWS 以外的任何地方。"
[[ -n "$GROUP" && -n "$OWNER" ]] || stop "缺少 GROUP 或 OWNER（組名與組內代號，不要用學號）。"

COMMIT="$(git rev-parse --verify --end-of-options "$COMMIT^{commit}")"
note "commit $COMMIT、AMI $AMI、子網 $SUBNET、SG 名稱 $SG_NAME、key pair $KEY_NAME"
note "標籤：course=$COURSE week=$WEEK group=$GROUP owner=$OWNER"

# ------------------------------------------------------------------ AWS 小幫手
aws_json() {
  python3 - "$@" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)
try:
    print(json.dumps(lab.run_aws(list(sys.argv[1:]), lab.context()["region"])))
except lab.LabError as exc:
    print("STOP: " + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}
jget() { python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
jstr() { python3 -c 'import json,sys;v=json.load(sys.stdin);print(v if isinstance(v,str) else json.dumps(v))'; }

note ""
note "== 身分核對 =="
bash scripts/verify-aws.sh || stop "身分核對未通過，不要建立任何資源。"

note ""
note "== 網路核對（唯讀） =="
VPC_ID="$(aws_json ec2 describe-subnets --subnet-ids "$SUBNET" \
  --query 'Subnets[0].{Vpc:VpcId,Az:AvailabilityZone,DefaultForAz:DefaultForAz,MapPublicIp:MapPublicIpOnLaunch}' \
  | jget Vpc)" || stop "查不到子網 $SUBNET。"
SUBNET_INFO="$(aws_json ec2 describe-subnets --subnet-ids "$SUBNET" \
  --query 'Subnets[0].{Az:AvailabilityZone,DefaultForAz:DefaultForAz,MapPublicIp:MapPublicIpOnLaunch}')"
note "  VPC $VPC_ID、可用區 $(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["Az"])' "$SUBNET_INFO")"
if [[ "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["MapPublicIp"])' "$SUBNET_INFO")" != "true" ]]; then
  note "  [注意] 這個子網的 MapPublicIpOnLaunch 不是 true；已改用 --associate-public-ip-address 指定公開位址。"
fi
# 子網實際使用的路由表要有 0.0.0.0/0 → igw-；沒有預設網路就停下來求助，不自己新建。
RT_ID="$(aws_json ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
  --query 'RouteTables[0].RouteTableId' | jstr)" || stop "查不到 VPC $VPC_ID 的 main 路由表。"
IGW_ROUTE="$(aws_json ec2 describe-route-tables --route-table-ids "$RT_ID" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" | jstr)"
if [[ -z "$IGW_ROUTE" || "$IGW_ROUTE" == "None" || "$IGW_ROUTE" == "null" ]]; then
  stop "子網使用的路由表 $RT_ID 沒有 0.0.0.0/0 → igw-…，不是公有子網。停下來求助，不要自己新建 VPC。"
fi
note "  路由表 $RT_ID 有 0.0.0.0/0 → $IGW_ROUTE"

# 已經有同名主機就停（同一時間只留一台）。
EXISTING="$(aws_json ec2 describe-instances --filters "Name=tag:Name,Values=$SG_NAME" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Ip:PublicIpAddress}')"
EXISTING_IDS="$(python3 -c '
import json, sys
print(" ".join(i["Id"] for i in json.loads(sys.argv[1])))' "$EXISTING")"
if [[ -n "$EXISTING_IDS" ]]; then
  note ""
  note "  [警告] 已有未回收的主機：$EXISTING_IDS"
  if [[ $REPLACE -eq 0 ]]; then
    stop "同一時間只留一台主機。先用回收腳本 terminate 舊主機，或明確加 --replace（會同時兩台並雙份計費）。"
  fi
fi

# ------------------------------------------------------------------ 來源 /32
EGRESS="$(curl -4 -sS --max-time 8 https://checkip.amazonaws.com)" || stop "查不到本機出口 IP。"
CIDR="$EGRESS/32"
note ""
note "== 來源 /32 =="
note "  本機出口 $EGRESS → SG 只放行 $CIDR 的 TCP 22 與 80（不放寬成 0.0.0.0/0）"

# ------------------------------------------------------------------ 印出將建立的清單
note ""
note "== 將要建立的資源（尚未建立） =="
note "  1. Security Group  $SG_NAME    入站 tcp 22、80，來源 $CIDR"
note "  2. Key Pair（匯入）  $KEY_NAME   來源 ~/.ssh/$KEY_NAME.pub（只有公鑰）"
note "  3. EC2 instance    AL2023 t3.micro、IMDSv2 required、根磁碟 gp3 8GiB 加密 DeleteOnTermination"
note "     子網 $SUBNET、user data $PACKAGE（$COMMIT）"
note "     標籤 course=$COURSE week=$WEEK group=$GROUP owner=$OWNER Name=$SG_NAME"
note "  4. 產生的 EBS 根磁碟與 ENI（跟著 instance，終止時一併刪除）"
note ""
note "  費用：EC2 t3.micro on-demand + EBS gp3 8GiB + 公有 IPv4；停止時仍收 EBS。"
note "  回收：用 deploy/down.sh 以 ID 逐項刪除（此腳本不提供回收）。"

if [[ $DRY_RUN -eq 1 ]]; then
  note ""
  note "DRY RUN：沒有建立任何資源，沒有呼叫任何寫入 API。"
  exit 0
fi

[[ -t 0 ]] || stop "需要互動式終端機輸入確認字串。請你在自己的終端機執行本指令。"
TOKEN="CREATE-$SG_NAME"
printf '\n輸入 %s 開始建立（其他任何輸入都會中止）: ' "$TOKEN"
[[ "$(read -r)" == "$TOKEN" ]] || stop "已中止，沒有建立任何資源。"

# ------------------------------------------------------------------ 1. SG
note ""
note "== 1/4 建立 Security Group =="
TAGS_SG="ResourceType=security-group,Tags=[{Key=course,Value=$COURSE},{Key=week,Value=$WEEK},{Key=group,Value=$GROUP},{Key=owner,Value=$OWNER},{Key=Name,Value=$SG_NAME}]"
SG_ID="$(aws_json ec2 create-security-group --group-name "$SG_NAME" \
  --description "course inspection host, $WEEK" --vpc-id "$VPC_ID" --tag-specifications "$TAGS_SG" | jget GroupId)" \
  || stop "SG 建立失敗。若已存在同名 SG，請先查清楚再用 ID 處理，不要順手刪別人的。"
note "  SG $SG_ID"
aws_json ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$CIDR,Description=SSH from my codespace}]" >/dev/null \
  || stop "SG 的 22 規則失敗。"
aws_json ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$CIDR,Description=HTTP from my codespace}]" >/dev/null \
  || stop "SG 的 80 規則失敗。"
note "  已放行 tcp 22、tcp 80，來源 $CIDR"

# ------------------------------------------------------------------ 2. Key pair
note ""
note "== 2/4 匯入 Key Pair =="
KEY_ID="$(aws_json ec2 import-key-material --key-name "$KEY_NAME" \
  --public-key-material "file://$PUBKEY" | jget KeyFingerprint)" || stop "匯入金鑰失敗。"
note "  key pair $KEY_NAME（指紋 ${KEY_ID:0:16}…；只匯入公鑰）"

# ------------------------------------------------------------------ 3. 打包 + 開機
note ""
note "== 3/4 打包 user data 並啟動實例 =="
rm -f "$PACKAGE"
bash deploy/make-user-data.sh "$COMMIT" "$PACKAGE" || stop "打包失敗，沒有建立 instance。"
TAGS_INSTANCE="ResourceType=instance,Tags=[{Key=course,Value=$COURSE},{Key=week,Value=$WEEK},{Key=group,Value=$GROUP},{Key=owner,Value=$OWNER},{Key=Name,Value=$SG_NAME}]"
TAGS_VOLUME="ResourceType=volume,Tags=[{Key=course,Value=$COURSE},{Key=week,Value=$WEEK},{Key=group,Value=$GROUP},{Key=owner,Value=$OWNER},{Key=Name,Value=$SG_NAME}]"
RUN_OUT="$(aws_json ec2 run-instances \
  --image-id "$AMI" --instance-type t3.micro --subnet-id "$SUBNET" \
  --security-group-ids "$SG_ID" --key-name "$KEY_NAME" --count 1 \
  --associate-public-ip-address \
  --metadata-options http-tokens=required,http-endpoint=enabled \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
  --tag-specifications "$TAGS_INSTANCE" "$TAGS_VOLUME" \
  --user-data "file://$PACKAGE" \
  --query 'Instances[0].{Id:InstanceId,State:State.Name}')" || stop "啟動 instance 失敗；SG 與 key pair 已建立，請記下它們的 ID。"
INSTANCE_ID="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["Id"])' "$RUN_OUT")"
note "  instance $INSTANCE_ID（user data 檔未自行 base64，交由 AWS CLI 編碼一次）"

# ------------------------------------------------------------------ 4. early curl
note ""
note "== 4/4 等待與驗證 =="
for _ in $(seq 1 12); do
  sleep "$EARLY_WAIT"
  STATE="$(aws_json ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin))')"
  [[ "$STATE" == "running" ]] && break
done
note "  狀態：$STATE"
[[ "$STATE" == "running" ]] || stop "主機沒有變成 running，請查一下再決定要不要回收。"

# 立刻 curl 一次，保留「服務還沒好」的真實樣子。
# 先等公開位址出來，再「立刻」curl 一次，保留「服務還沒好」的真實樣子。
EARLY_BODY="$(mktemp)"
IP=""
for _ in $(seq 1 20); do
  IP="$(aws_json ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin) or "")')"
  [[ -n "$IP" ]] && break
  sleep 5
done
[[ -n "$IP" ]] || stop "拿不到公開位址，無法做 early curl 與後續驗證。"
EARLY_HTTP="$(curl -4 -sS --max-time 8 -o "$EARLY_BODY" -w '%{http_code}' "http://$IP/health" 2>/dev/null)" && EARLY_EXIT=0 || EARLY_EXIT=$?
EARLY_SNIPPET="$(head -c 200 "$EARLY_BODY" 2>/dev/null || true)"
rm -f "$EARLY_BODY"
note "  early curl（拿到位址後立刻打）：exit=$EARLY_EXIT http=${EARLY_HTTP:-000} → http://$IP/health"
[[ -n "$EARLY_SNIPPET" ]] && note "  early curl 內容：$EARLY_SNIPPET"

# 狀態檢查 2/2
TWO_OF_TWO="no"
for _ in $(seq 1 "$STATUS_TRIES"); do
  ST="$(aws_json ec2 describe-instance-status --instance-ids "$INSTANCE_ID" --include-all-instances \
    --query 'InstanceStatuses[0].{Sys:SystemStatus.Status,Inst:InstanceStatus.Status}')"
  SYS="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["Sys"])' "$ST")"
  INST="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["Inst"])' "$ST")"
  if [[ "$SYS" == "ok" && "$INST" == "ok" ]]; then TWO_OF_TWO="yes"; break; fi
  sleep "$STATUS_WAIT"
done
note "  狀態檢查 2/2：$TWO_OF_TWO（system=$SYS instance=$INST）"

# /health 200 且 version 等於 commit
HEALTH_BODY=""
for _ in $(seq 1 "$HEALTH_TRIES"); do
  HEALTH_BODY="$(curl -4 -sS --max-time 8 "http://$IP/health" 2>/dev/null || true)"
  if [[ -n "$HEALTH_BODY" ]]; then break; fi
  sleep "$HEALTH_WAIT"
done
note "  /health：$HEALTH_BODY"
python3 -c '
import json, sys
try:
    body = json.loads(sys.argv[1])
except ValueError:
    raise SystemExit("STOP: /health 沒有回應；請用 SSH 看 cloud-init 與 systemctl 狀態。")
if body.get("version") != sys.argv[2]:
    raise SystemExit("STOP: version 是 " + str(body.get("version")) + "，不是部署的 commit。")
print("  version 等於 " + sys.argv[2])' "$HEALTH_BODY" "$COMMIT" || stop "驗證未通過。"

# ------------------------------------------------------------------ 5. 寫下 ID
VOLUME_ID="$(aws_json ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  --query 'Volumes[0].VolumeId' | jstr)"
ENI_ID="$(aws_json ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  --query 'NetworkInterfaces[0].NetworkInterfaceId' | jstr)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$RESOURCES" "$INSTANCE_ID" "$SUBNET" "$AMI" "$SG_ID" "$KEY_NAME" "$VOLUME_ID" "$ENI_ID" "$IP" "$COMMIT" "$NOW" <<'PY' \
  || stop "寫入 $RESOURCES 失敗（請手動把上面印出的 ID 記下來）。"
import json, pathlib, sys
path, iid, subnet, ami, sg, key, vol, eni, ip, commit, now = sys.argv[1:12]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8")) if pathlib.Path(path).exists() else {}
data["keypair"] = {"id": key, "name": key, "created_at": now}
data["sg"] = {"id": sg, "created_at": now}
data["instance"] = {"id": iid, "subnet": subnet, "ami": ami, "created_at": now,
                    "public_ip": ip, "launch_time": now}
data["volume"] = {"id": vol}
data["eni"] = {"id": eni}
data.setdefault("meta", {})["updated_at"] = now
data["meta"]["commit"] = commit
pathlib.Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("  已寫入 " + path)
PY

note ""
note "建立完成：instance $INSTANCE_ID、SG $SG_ID、key pair $KEY_NAME、volume $VOLUME_ID、eni $ENI_ID"
note "還沒記錄的證據（需要你自己用 SSH 收）：cloud-init 完成時間、nginx 80 與 inspection 127.0.0.1:8080 的監聽"
note "回收：deploy/down.sh（此腳本不提供回收）。結束記得 stop 或 terminate。"
