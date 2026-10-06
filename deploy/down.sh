#!/usr/bin/env bash
# deploy/down.sh：只依 .local/resources.json 記錄的 ID 回收資源，或只停止主機。
#
# 規格（labs/03-service-prototype/README.md）：
#   1. 只處理清單裡的 ID，不依名稱搜尋後大量刪除。
#   2. 刪除前核對標籤（course 與 owner），不符就停。
#   3. --stop 只停止主機，不刪任何東西。
#   4. 結束後讀回：主機 terminated（或 stopped），其餘四項查無。
#   5. 執行前先印出清單並要求輸入確認字串。
#
# 所有 AWS 指令都經過 scripts/lab.py 的 context()/run_aws()。
# 刪除順序：先讓主機自己帶走磁碟與網路介面，再刪 SG 與 key pair。
set -euo pipefail
cd "$(dirname "$0")/.."

STOP_ONLY=0
DRY_RUN=0
CONF=".local/w03.conf"
RESOURCES=".local/resources.json"
TERM_TRIES=40
TERM_WAIT=15

stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) STOP_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) stop "未知參數：$1" ;;
  esac
done

conf_get() { [[ -f "$CONF" ]] || return 1; sed -n "s/^$1=//p" "$CONF" | head -n 1; }
COURSE="$(conf_get COURSE || true)"; COURSE="${COURSE:-yuntech-115-1}"
OWNER="$(conf_get OWNER || true)"

[[ -f "$RESOURCES" ]] || stop "找不到 $RESOURCES，沒有可回收的 ID。不要憑記憶猜 ID。"

# 只讀清單裡的 ID；缺就停，不補、不猜。
field_of() {
  python3 -c '
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
node = data
for part in sys.argv[2].split("."):
    node = node.get(part) if isinstance(node, dict) else None
print(node if node else "")' "$RESOURCES" "$1"
}
INSTANCE_ID="$(field_of instance.id)"
SUBNET_ID="$(field_of instance.subnet)"
SG_ID="$(field_of sg.id)"
KEY_ID="$(field_of keypair.id)"
KEY_NAME="$(field_of keypair.name)"
VOLUME_ID="$(field_of volume.id)"
ENI_ID="$(field_of eni.id)"
[[ -n "$INSTANCE_ID" ]] || stop "清單裡沒有 instance.id。"
[[ -n "$SG_ID" ]] || stop "清單裡沒有 sg.id。"
[[ -n "$KEY_ID" ]] || stop "清單裡沒有 keypair.id。"

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
# 讀回時「查無」是預期結果，所以把錯誤當資料回傳。
aws_try() {
  python3 - "$@" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)
try:
    print(json.dumps(lab.run_aws(list(sys.argv[1:]), lab.context()["region"])))
except lab.LabError as exc:
    print(json.dumps({"absent": True, "reason": str(exc)}))
PY
}
jstr() { python3 -c 'import json,sys;v=json.load(sys.stdin);print(v if isinstance(v,str) else json.dumps(v))'; }
absent() { python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if isinstance(d,dict) and d.get("absent") else "no")'; }
# 清單沒記錄的 ID 就不要拿空字串去查（查不到會被誤讀成「已刪」）。
# 用法：probe <ec2> <describe-*> <ID 參數名> <ID> <query>
probe() {
  if [[ -z "$4" ]]; then printf '（清單未記錄）'; return; fi
  local out; out="$(aws_try "$1" "$2" "$3" "$4" --query "$5" | absent)"
  [[ "$out" == yes ]] && echo 查無 || echo 存在
}
# 有沒有成功執行（0 成功、1 被 policy 或權限擋下）。
aws_ok() {
  python3 - "$@" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)
try:
    lab.run_aws(list(sys.argv[1:]), lab.context()["region"])
except lab.LabError as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}

note ""
note "== 身分核對 =="
bash scripts/verify-aws.sh || stop "身分核對未通過，不做任何變更。"

# ------------------------------------------------------------------ 現況與標籤核對
note ""
note "== 清單上的資源（只依 .local/resources.json 的 ID） =="
INST="$(aws_try ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,Ip:PublicIpAddress,Tags:Tags}')"
if [[ "$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("absent",False))' <<<"$INST")" == "True" ]]; then
  note "  instance $INSTANCE_ID：查無（可能已回收）。仍會讀回其餘項目，不會重複刪。"
  STATE="absent"
else
  STATE="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["State"])' <<<"$INST")"
  note "  instance $INSTANCE_ID  狀態 $STATE  $(python3 -c 'import json,sys;print(json.load(sys.stdin)["Type"])' <<<"$INST")"
  # 標籤核對：course 與 owner 都要對得上，不對就停手。
  TAGS="$(python3 -c '
import json, sys
tags = {t["Key"]: t["Value"] for t in json.load(sys.stdin)["Tags"]}
print("{}|{}".format(tags.get("course", ""), tags.get("owner", "")))' <<<"$INST")"
  T_COURSE="${TAGS%%|*}"; T_OWNER="${TAGS##*|}"
  note "  標籤 course=$T_COURSE owner=$T_OWNER（預期 course=$COURSE owner=$OWNER）"
  if [[ "$T_COURSE" != "$COURSE" ]]; then
    stop "主機的 course 標籤是 $T_COURSE，不是 $COURSE；不要對不屬於本課程的資源動手。"
  fi
  if [[ -n "$OWNER" && "$T_OWNER" != "$OWNER" ]]; then
    stop "主機的 owner 標籤是 $T_OWNER，不是 $OWNER。請先確認是不是本人的資源。"
  fi
fi
note "  SG $SG_ID：$(probe ec2 describe-security-groups --group-ids "$SG_ID" 'SecurityGroups[0].GroupId')"
note "  EBS $VOLUME_ID：$(probe ec2 describe-volumes --volume-ids "$VOLUME_ID" 'Volumes[0].VolumeId')"
note "  ENI $ENI_ID：$(probe ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" 'NetworkInterfaces[0].NetworkInterfaceId')"
# 本課程 policy 禁止 describe-key-pairs（回 CommandFailed），所以 key pair 無法查證。
# 查不到 ≠ 不存在，不要在報告裡把它寫成「已刪除」。
KEY_VERIFY="無法查證（本課程 policy 禁止 describe-key-pairs）；刪除結果以下方實際輸出為準"
note "  key pair $KEY_ID（$KEY_NAME）：$KEY_VERIFY"

# ------------------------------------------------------------------ 印出清單並確認
note ""
if [[ $STOP_ONLY -eq 1 ]]; then
  note "== 將要停止（不刪除任何東西） =="
  note "  stop instance $INSTANCE_ID"
  note "  保留：SG $SG_ID、key pair $KEY_NAME、EBS $VOLUME_ID、ENI $ENI_ID"
  note "  費用：停止後不收 EC2 運算費，EBS 仍計費，公開 IPv4 不計費；Start 後公開位址會改變。"
  ACTION="停止"; TOKEN="STOP-${INSTANCE_ID:0:8}"
else
  note "== 將要刪除（全部依清單上的 ID） =="
  note "  terminate instance $INSTANCE_ID（根磁碟 $VOLUME_ID、ENI $ENI_ID 會跟著刪除）"
  note "  delete SG $SG_ID"
  note "  delete key pair $KEY_NAME（$KEY_ID）"
  note "  保留：預設 VPC、子網 $SUBNET_ID、路由表、其他人的資源一律不碰"
  note "  費用：刪除後 EC2 運算費與 EBS 費都停止；下週要重建得重新執行 deploy/up.sh。"
  ACTION="回收"; TOKEN="RECLAIM-${INSTANCE_ID:0:8}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  note ""
  note "DRY RUN：沒有停止、沒有刪除任何資源。"
  exit 0
fi

[[ -t 0 ]] || stop "需要互動式終端機輸入確認字串。請你在自己的終端機執行本指令。"
printf '\n輸入 %s 執行%s（其他任何輸入都會中止）: ' "$TOKEN" "$ACTION"
[[ "$(read -r)" == "$TOKEN" ]] || stop "已中止，沒有任何變更。"

# ------------------------------------------------------------------ 執行
if [[ $STOP_ONLY -eq 1 ]]; then
  note ""
  note "== 停止主機 =="
  aws_json ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
  for _ in $(seq 1 20); do
    sleep 15
    S="$(aws_try ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' | jstr)"
    [[ "$S" == "stopped" || "$S" == '"stopped"' ]] && break
  done
  note "  讀回 instance $INSTANCE_ID：$S"
  note "  保留的資源：SG $SG_ID、key pair $KEY_NAME、EBS $VOLUME_ID、ENI $ENI_ID"
  exit 0
fi

note ""
note "== 終止主機 =="
aws_json ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
for _ in $(seq 1 "$TERM_TRIES"); do
  sleep "$TERM_WAIT"
  S="$(aws_try ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' | jstr)"
  case "$S" in
    terminated|'"terminated"'|absent|'"absent"') break ;;
  esac
done
note "  instance 狀態：$S（terminated 會暫留一陣子，不必等它消失）"

note ""
note "== 刪除 SG 與 key pair =="
if aws_ok ec2 delete-security-group --group-id "$SG_ID" >/dev/null; then
  note "  已送出刪除 SG $SG_ID"
else
  note "  SG 刪除未成功（可能還有 ENI 依附或被 policy 擋下）；以下方讀回為準"
fi
if aws_ok ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null; then
  note "  已送出刪除 key pair $KEY_NAME"
else
  note "  key pair 刪除未成功（本課程 policy 多半不允許）；報告請寫需教師處理，不要寫成已刪除"
fi

# ------------------------------------------------------------------ 讀回
note ""
note "== 回收後讀回 =="
FINAL="$(aws_try ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' | jstr)"
note "  instance $INSTANCE_ID → $FINAL（terminated 會暫留一陣子，不必等它消失）"
note "  SG $SG_ID → $(probe ec2 describe-security-groups --group-ids "$SG_ID" 'SecurityGroups[0].GroupId')"
note "  EBS $VOLUME_ID → $(probe ec2 describe-volumes --volume-ids "$VOLUME_ID" 'Volumes[0].VolumeId')"
note "  ENI $ENI_ID → $(probe ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" 'NetworkInterfaces[0].NetworkInterfaceId')"
note "  key pair $KEY_NAME → 無法查證（policy 限制）；以上方刪除指令的實際結果為準"

python3 - "$RESOURCES" "$INSTANCE_ID" "$SG_ID" "$KEY_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, pathlib, sys
path, iid, sg, key, now = sys.argv[1:6]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
data.setdefault("reclaimed", []).append(
    {"at": now, "instance": iid, "sg": sg, "keypair": key})
pathlib.Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("  已在 " + path + " 記錄回收時間與 ID")
PY

note ""
note "回收完成。預設 VPC、子網與其他人的資源都沒有動。"
