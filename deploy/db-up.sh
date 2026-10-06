#!/usr/bin/env bash
# Create or safely resume the W5 private PostgreSQL resources. Never configures IAM.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
RESUME=0
CONFIG=".local/w05.conf"
RESOURCES=".local/resources.json"
DB_ENV=".local/db.env"
REQUEST_FILE=""

stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --config)
      [[ $# -ge 2 ]] || stop "--config requires a file path"
      CONFIG="$2"
      shift 2
      ;;
    *) stop "Unknown argument: $1" ;;
  esac
done

[[ -f "$RESOURCES" ]] || stop "Missing $RESOURCES. Create the W3 host with deploy/up.sh first."
[[ -f "$CONFIG" ]] || stop "Missing $CONFIG; see the W5 README for required subnet, AZ, identifier, and budget settings."
[[ ! -L "$RESOURCES" && ! -L "$CONFIG" ]] || stop "Refusing symlinked local configuration or resource files."
mkdir -p .local
chmod 700 .local

conf_get() {
  sed -n "s/^$1=//p" "$CONFIG" | head -n 1
}
w3_conf_get() {
  [[ -f .local/w03.conf ]] || return 1
  sed -n "s/^$1=//p" .local/w03.conf | head -n 1
}

COURSE="$(conf_get COURSE || true)"; COURSE="${COURSE:-yuntech-115-1}"
WEEK="w05"
GROUP="$(conf_get GROUP || true)"
OWNER="$(conf_get OWNER || true)"
GROUP="${GROUP:-$(w3_conf_get GROUP || true)}"
OWNER="${OWNER:-$(w3_conf_get OWNER || true)}"
DB_SUBNET_1_CIDR="$(conf_get DB_SUBNET_1_CIDR || true)"
DB_SUBNET_1_AZ="$(conf_get DB_SUBNET_1_AZ || true)"
DB_SUBNET_2_CIDR="$(conf_get DB_SUBNET_2_CIDR || true)"
DB_SUBNET_2_AZ="$(conf_get DB_SUBNET_2_AZ || true)"
DB_IDENTIFIER="$(conf_get DB_INSTANCE_IDENTIFIER || true)"
MONTHLY_BUDGET="$(conf_get DB_MONTHLY_BUDGET_USD || true)"
DB_USER="inspection_admin"

[[ "$COURSE" == "yuntech-115-1" ]] || stop "Unexpected COURSE in $CONFIG."
python3 - "$GROUP" "$OWNER" <<'PY' || stop "Set GROUP and OWNER to valid tag values in $CONFIG."
import sys

for label, value in (("GROUP", sys.argv[1]), ("OWNER", sys.argv[2])):
    if not value or len(value) > 32 or not all(
        char.isalnum() or char in "-_" for char in value
    ):
        raise SystemExit(
            f"{label} must be 1-32 letters/digits, hyphens, or underscores."
        )
PY
[[ "$DB_SUBNET_1_CIDR" =~ ^[0-9./]+$ && "$DB_SUBNET_2_CIDR" =~ ^[0-9./]+$ ]] || stop "Set both private /24 CIDRs in $CONFIG."
[[ -n "$DB_SUBNET_1_AZ" && -n "$DB_SUBNET_2_AZ" && "$DB_SUBNET_1_AZ" != "$DB_SUBNET_2_AZ" ]] \
  || stop "Set two different available AZ names in $CONFIG."
[[ "$DB_IDENTIFIER" =~ ^[a-z][a-z0-9-]{0,62}[a-z0-9]$ ]] \
  || stop "DB_INSTANCE_IDENTIFIER must be 2-64 lowercase letters, digits, or hyphens; start with a letter."
[[ "$MONTHLY_BUDGET" =~ ^[0-9]+([.][0-9]{1,2})?$ ]] \
  || stop "Set DB_MONTHLY_BUDGET_USD after checking current regional RDS and gp3 pricing."
awk -v amount="$MONTHLY_BUDGET" 'BEGIN { exit !(amount > 0) }' \
  || stop "DB_MONTHLY_BUDGET_USD must be greater than zero."
HAS_W05_RECORDS="$(python3 - "$RESOURCES" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print("yes" if data.get("w05") else "no")
PY
)"
if [[ "$HAS_W05_RECORDS" == "yes" && "$RESUME" != "1" ]]; then
  stop "Partial W5 records exist. Verify their AWS state, then use --resume; do not create duplicates."
fi
if [[ "$HAS_W05_RECORDS" == "no" && "$RESUME" == "1" ]]; then
  stop "--resume requested, but $RESOURCES has no W5 resource records."
fi
if [[ -e "$DB_ENV" && "$RESUME" != "1" ]]; then
  stop "$DB_ENV already exists. Do not overwrite database credentials; inspect existing state first."
fi
if [[ -e "$DB_ENV" ]]; then
  stop "$DB_ENV already exists; database-creation recovery needs manual review. Do not overwrite it."
fi

get_record() {
  python3 - "$RESOURCES" "$1" <<'PY'
import json, pathlib, sys
node = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for part in sys.argv[2].split("."):
    node = node.get(part) if isinstance(node, dict) else None
print(node or "")
PY
}
INSTANCE_ID="$(get_record instance.id)"
HOST_SG_ID="$(get_record sg.id)"
[[ -n "$INSTANCE_ID" && -n "$HOST_SG_ID" ]] || stop "The resource manifest must contain instance.id and sg.id."

aws_json() {
  python3 - "$@" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
try:
    ctx = lab.context()
    print(json.dumps(lab.run_aws(list(sys.argv[1:]), ctx["region"],
                                 env=lab.clean_env(ctx["region"]))))
except lab.LabError as exc:
    print("STOP: " + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}

tag_specs() {
  python3 - "$@" <<'PY'
import json, sys
resource_type, name, course, week, group, owner = sys.argv[1:]
tags = [
    {"Key": "course", "Value": course},
    {"Key": "week", "Value": week},
    {"Key": "group", "Value": group},
    {"Key": "owner", "Value": owner},
    {"Key": "Name", "Value": name},
]
print(json.dumps([{"ResourceType": resource_type, "Tags": tags}], separators=(",", ":")))
PY
}

save_record() {
  python3 - "$RESOURCES" "$1" "$2" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
parts = sys.argv[2].split(".")
value = json.loads(sys.argv[3])
data = json.loads(path.read_text(encoding="utf-8"))
node = data
for part in parts[:-1]:
    node = node.setdefault(part, {})
node[parts[-1]] = value
data.setdefault("meta", {})["updated_at"] = __import__("datetime").datetime.now(
    __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fd, temporary = tempfile.mkstemp(prefix=".resources-", dir=path.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

note "== Identity check =="
bash scripts/verify-aws.sh || stop "Learner Lab identity check failed; no changes made."

note ""
note "== Verify the existing host and VPC =="
HOST_INFO="$(aws_json ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Vpc:VpcId,Subnet:SubnetId,Groups:SecurityGroups[].GroupId,Tags:Tags}')"
python3 - "$HOST_INFO" "$HOST_SG_ID" "$COURSE" "$GROUP" "$OWNER" <<'PY'
import json, sys
host = json.loads(sys.argv[1])
if not host.get("Vpc"):
    raise SystemExit("STOP: the recorded EC2 instance was not found.")
if host.get("State") != "running":
    raise SystemExit("STOP: recorded EC2 host must be running.")
if sys.argv[2] not in host.get("Groups", []):
    raise SystemExit("STOP: recorded host security group is not attached to this instance.")
tags = {item["Key"]: item["Value"] for item in host.get("Tags", [])}
for key, expected in (("course", sys.argv[3]), ("group", sys.argv[4]), ("owner", sys.argv[5])):
    if tags.get(key) != expected:
        raise SystemExit("STOP: EC2 ownership tag mismatch for " + key + ".")
print("Instance " + host["State"] + "; VPC " + host["Vpc"] +
      "; subnet " + host["Subnet"] + "; host SG " + sys.argv[2])
PY
VPC_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Vpc"])' "$HOST_INFO")"
REGION="$(python3 - "$VPC_ID" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lab", "scripts/lab.py")
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)
print(lab.context()["region"])
PY
)"

VPC_CIDR="$(aws_json ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' | python3 -c 'import json,sys; print(json.load(sys.stdin))')"
SUBNETS_JSON="$(aws_json ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{Id:SubnetId,Cidr:CidrBlock,Az:AvailabilityZone}')"
AZ_JSON="$(aws_json ec2 describe-availability-zones --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName')"
RECORDED_SUBNET_1="$(get_record w05.subnet_1.id)"
RECORDED_SUBNET_2="$(get_record w05.subnet_2.id)"
python3 - "$VPC_CIDR" "$DB_SUBNET_1_CIDR" "$DB_SUBNET_2_CIDR" \
  "$SUBNETS_JSON" "$AZ_JSON" "$DB_SUBNET_1_AZ" "$DB_SUBNET_2_AZ" \
  "$RECORDED_SUBNET_1" "$RECORDED_SUBNET_2" <<'PY'
import ipaddress, json, sys
vpc = ipaddress.ip_network(sys.argv[1])
new = [ipaddress.ip_network(sys.argv[2]), ipaddress.ip_network(sys.argv[3])]
if any(net.prefixlen != 24 for net in new):
    raise SystemExit("STOP: both database subnets must be /24.")
if any(not net.subnet_of(vpc) for net in new):
    raise SystemExit("STOP: database subnet CIDRs must be inside the host VPC CIDR.")
if new[0].overlaps(new[1]):
    raise SystemExit("STOP: the two proposed database subnets overlap.")
existing = json.loads(sys.argv[4])
recorded_ids = set(sys.argv[8:10])
for candidate in new:
    for subnet in existing:
        if subnet["Id"] in recorded_ids:
            continue
        if candidate.overlaps(ipaddress.ip_network(subnet["Cidr"])):
            raise SystemExit("STOP: proposed CIDR overlaps existing subnet " +
                             subnet["Id"] + " (" + subnet["Cidr"] + ").")
azs = set(json.loads(sys.argv[5]))
for name in sys.argv[6:8]:
    if name not in azs:
        raise SystemExit("STOP: AZ " + name + " is not currently available in this region.")
print("Proposed subnets are non-overlapping /24s in two available AZs.")
PY

EXISTING_DB="$(aws_json rds describe-db-instances \
  --filters "Name=db-instance-id,Values=$DB_IDENTIFIER" \
  --query 'DBInstances[].DBInstanceIdentifier')"
python3 - "$EXISTING_DB" "$DB_IDENTIFIER" <<'PY'
import json, sys
matches = json.loads(sys.argv[1])
if matches:
    raise SystemExit("STOP: RDS identifier " + sys.argv[2] +
                     " already exists; inspect that exact resource before proceeding.")
PY

DB_GROUP_NAME="${DB_IDENTIFIER}-sg"
DB_SUBNET_GROUP="${DB_IDENTIFIER}-subnets"
note ""
note "== Exact plan (recorded resources are checked and reused) =="
note "Region: $REGION; VPC: $VPC_ID ($VPC_CIDR)"
note "Existing host: $INSTANCE_ID; source SG: $HOST_SG_ID"
for index in 1 2; do
  if [[ -n "$(get_record "w05.subnet_${index}.id")" ]]; then
    note "Reuse: verify recorded private subnet $(get_record "w05.subnet_${index}.id")"
  elif [[ "$index" == 1 ]]; then
    note "Create: private subnet $DB_SUBNET_1_CIDR in $DB_SUBNET_1_AZ"
  else
    note "Create: private subnet $DB_SUBNET_2_CIDR in $DB_SUBNET_2_AZ"
  fi
done
if [[ -n "$(get_record w05.route_table.id)" ]]; then
  note "Reuse: verify recorded local-only route table $(get_record w05.route_table.id) and both subnet associations"
else
  note "Create: one route table with local route only, plus explicit associations to both subnets"
fi
if [[ -n "$(get_record w05.db_subnet_group.name)" ]]; then
  note "Reuse: verify DB subnet group $DB_SUBNET_GROUP"
else
  note "Create: DB subnet group $DB_SUBNET_GROUP"
fi
if [[ -n "$(get_record w05.db_security_group.id)" ]]; then
  note "Reuse: verify DB SG $(get_record w05.db_security_group.id)"
else
  note "Create: DB SG $DB_GROUP_NAME with only inbound TCP 5432 from $HOST_SG_ID"
fi
note "Create: one encrypted, non-public, single-AZ PostgreSQL db.t3.micro, 20 GiB gp3, database inspection"
note "Credential: generate DB password into $DB_ENV (mode 600); never display it."
note "Monthly budget target you entered: USD $MONTHLY_BUDGET (not an AWS-enforced cap; verify current regional pricing)."
note "Costs: RDS compute and 20 GiB storage accrue; stopping RDS is temporary (AWS may restart it after 7 days)."
note "Exposure: no public DB address; only the existing EC2 SG can reach port 5432."
note "Recovery: use the exact IDs written to $RESOURCES; stop RDS to reduce compute charges, and remove only owned IDs after verifying dependencies."
note "No NAT, public IP, IAM, or existing VPC resources will be created or changed."

if [[ "$DRY_RUN" == "1" ]]; then
  note "DRY RUN: read-only checks only; no AWS resources created."
  exit 0
fi
[[ -t 0 ]] || stop "Interactive confirmation required; run this from your terminal."
CONFIRM="CREATE-$DB_IDENTIFIER"
printf '\nType %s to create exactly this plan: ' "$CONFIRM"
read -r CONFIRMATION
[[ "$CONFIRMATION" == "$CONFIRM" ]] || stop "Cancelled; no resources created."

trap '[[ -n "$REQUEST_FILE" && -e "$REQUEST_FILE" ]] && rm -f -- "$REQUEST_FILE"' EXIT

create_subnet() {
  local index="$1" cidr="$2" az="$3" name="$4" output id now existing
  existing="$(get_record "w05.subnet_${index}.id")"
  if [[ -n "$existing" ]]; then
    output="$(aws_json ec2 describe-subnets --subnet-ids "$existing" \
      --query 'Subnets[0].{Id:SubnetId,Vpc:VpcId,Cidr:CidrBlock,Az:AvailabilityZone,Tags:Tags}')"
    python3 - "$output" "$VPC_ID" "$cidr" "$az" "$COURSE" "$WEEK" "$GROUP" "$OWNER" <<'PY'
import json, sys
subnet = json.loads(sys.argv[1])
if (subnet.get("Vpc") != sys.argv[2] or subnet.get("Cidr") != sys.argv[3]
        or subnet.get("Az") != sys.argv[4]):
    raise SystemExit("STOP: recorded subnet does not match the approved VPC/CIDR/AZ.")
tags = {item["Key"]: item["Value"] for item in subnet.get("Tags", [])}
for key, expected in zip(("course", "week", "group", "owner"), sys.argv[5:9]):
    if tags.get(key) != expected:
        raise SystemExit("STOP: recorded subnet ownership tag mismatch for " + key + ".")
PY
    note "Verified recorded subnet $existing ($cidr, $az); reusing it."
    return
  fi
  output="$(aws_json ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
    --availability-zone "$az" \
    --tag-specifications "$(tag_specs subnet "$name" "$COURSE" "$WEEK" "$GROUP" "$OWNER")" \
    --query 'Subnet.{Id:SubnetId,Cidr:CidrBlock,Az:AvailabilityZone}')"
  id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Id"])' "$output")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_record "w05.subnet_${index}" \
    "$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"cidr":sys.argv[2],"az":sys.argv[3],"created_at":sys.argv[4]}))' "$id" "$cidr" "$az" "$now")"
  note "Created subnet $id ($cidr, $az); ID saved to $RESOURCES."
}

create_subnet 1 "$DB_SUBNET_1_CIDR" "$DB_SUBNET_1_AZ" "${DB_IDENTIFIER}-private-a"
create_subnet 2 "$DB_SUBNET_2_CIDR" "$DB_SUBNET_2_AZ" "${DB_IDENTIFIER}-private-b"
SUBNET_1_ID="$(get_record w05.subnet_1.id)"
SUBNET_2_ID="$(get_record w05.subnet_2.id)"

RT_ID="$(get_record w05.route_table.id)"
if [[ -n "$RT_ID" ]]; then
  RT_OUT="$(aws_json ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].{Id:RouteTableId,Vpc:VpcId,Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId},Tags:Tags}')"
  python3 - "$RT_OUT" "$VPC_ID" "$COURSE" "$WEEK" "$GROUP" "$OWNER" <<'PY'
import json, sys
route_table = json.loads(sys.argv[1])
if route_table.get("Vpc") != sys.argv[2]:
    raise SystemExit("STOP: recorded route table is not in the EC2 VPC.")
routes = route_table.get("Routes", [])
if len(routes) != 1 or routes[0].get("Gateway") != "local":
    raise SystemExit("STOP: recorded route table is not local-only.")
tags = {item["Key"]: item["Value"] for item in route_table.get("Tags", [])}
for key, expected in zip(("course", "week", "group", "owner"), sys.argv[3:7]):
    if tags.get(key) != expected:
        raise SystemExit("STOP: recorded route table ownership tag mismatch for " + key + ".")
PY
  note "Verified recorded local-only route table $RT_ID; reusing it."
else
  RT_OUT="$(aws_json ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_specs route-table "${DB_IDENTIFIER}-private" "$COURSE" "$WEEK" "$GROUP" "$OWNER")" \
    --query 'RouteTable.{Id:RouteTableId,Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId}}')"
  RT_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Id"])' "$RT_OUT")"
  save_record "w05.route_table" \
    "$(python3 -c 'import json,sys,datetime;print(json.dumps({"id":sys.argv[1],"created_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$RT_ID")"
  note "Created route table $RT_ID; ID saved to $RESOURCES."
fi
python3 - "$RT_OUT" <<'PY'
import json, sys
routes = json.loads(sys.argv[1]).get("Routes", [])
if len(routes) != 1 or routes[0].get("Gateway") != "local":
    raise SystemExit("STOP: new route table is not local-only. Inspect recorded route table ID; do not proceed.")
PY

associate_subnet() {
  local subnet_id="$1" index="$2" association_id route_check
  route_check="$(aws_json ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[].{Id:RouteTableAssociationId,SubnetId:SubnetId,Main:Main}')"
  association_id="$(python3 - "$route_check" "$subnet_id" <<'PY'
import json, sys
for association in json.loads(sys.argv[1]):
    if association.get("SubnetId") == sys.argv[2] and association.get("Main") is False:
        print(association["Id"])
        break
PY
)"
  if [[ -z "$association_id" ]]; then
    association_id="$(aws_json ec2 associate-route-table --route-table-id "$RT_ID" \
      --subnet-id "$subnet_id" --query 'AssociationId' |
      python3 -c 'import json,sys; print(json.load(sys.stdin))')"
  fi
  save_record "w05.route_association_${index}" \
    "$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"subnet_id":sys.argv[2]}))' "$association_id" "$subnet_id")"
  note "Verified association for subnet $subnet_id to $RT_ID ($association_id); ID saved."
}
associate_subnet "$SUBNET_1_ID" 1
associate_subnet "$SUBNET_2_ID" 2

ROUTE_CHECK="$(aws_json ec2 describe-route-tables --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].{Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId},Associations:Associations[].SubnetId}')"
python3 - "$ROUTE_CHECK" "$SUBNET_1_ID" "$SUBNET_2_ID" <<'PY'
import json, sys
info = json.loads(sys.argv[1])
routes = info.get("Routes", [])
if len(routes) != 1 or routes[0].get("Gateway") != "local":
    raise SystemExit("STOP: private route table is not local-only.")
if set(info.get("Associations", [])) != set(sys.argv[2:]):
    raise SystemExit("STOP: explicit route-table subnet associations did not read back as expected.")
PY

RECORDED_DB_SUBNET_GROUP="$(get_record w05.db_subnet_group.name)"
if [[ -n "$RECORDED_DB_SUBNET_GROUP" ]]; then
  [[ "$RECORDED_DB_SUBNET_GROUP" == "$DB_SUBNET_GROUP" ]] \
    || stop "Recorded DB subnet group name differs from configuration."
  DB_SUBNET_GROUP_INFO="$(aws_json rds describe-db-subnet-groups \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --query 'DBSubnetGroups[0].{Vpc:VpcId,Status:SubnetGroupStatus,Subnets:Subnets[].SubnetIdentifier}')"
  python3 - "$DB_SUBNET_GROUP_INFO" "$VPC_ID" "$SUBNET_1_ID" "$SUBNET_2_ID" <<'PY'
import json, sys
group = json.loads(sys.argv[1])
if group.get("Vpc") != sys.argv[2] or group.get("Status") != "Complete":
    raise SystemExit("STOP: recorded DB subnet group VPC/status does not match.")
if set(group.get("Subnets", [])) != set(sys.argv[3:]):
    raise SystemExit("STOP: DB subnet group does not contain exactly the two recorded subnets.")
PY
  note "Verified DB subnet group $DB_SUBNET_GROUP; reusing it."
else
  aws_json rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Private W5 subnets for $DB_IDENTIFIER" \
    --subnet-ids "$SUBNET_1_ID" "$SUBNET_2_ID" \
    --tags "Key=course,Value=$COURSE" "Key=week,Value=$WEEK" \
           "Key=group,Value=$GROUP" "Key=owner,Value=$OWNER" >/dev/null
  save_record "w05.db_subnet_group" \
    "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$DB_SUBNET_GROUP")"
  note "Created DB subnet group $DB_SUBNET_GROUP; recorded."
fi

DB_SG_ID="$(get_record w05.db_security_group.id)"
if [[ -n "$DB_SG_ID" ]]; then
  DB_SG_INFO="$(aws_json ec2 describe-security-groups --group-ids "$DB_SG_ID" \
    --query 'SecurityGroups[0].{Vpc:VpcId,GroupName:GroupName,Tags:Tags}')"
  python3 - "$DB_SG_INFO" "$VPC_ID" "$DB_GROUP_NAME" "$COURSE" "$WEEK" "$GROUP" "$OWNER" <<'PY'
import json, sys
sg = json.loads(sys.argv[1])
if sg.get("Vpc") != sys.argv[2] or sg.get("GroupName") != sys.argv[3]:
    raise SystemExit("STOP: recorded DB security group does not match the approved VPC/name.")
tags = {item["Key"]: item["Value"] for item in sg.get("Tags", [])}
for key, expected in zip(("course", "week", "group", "owner"), sys.argv[4:8]):
    if tags.get(key) != expected:
        raise SystemExit("STOP: recorded DB security group ownership tag mismatch for " + key + ".")
PY
  note "Verified recorded DB security group $DB_SG_ID; reusing it."
else
  DB_SG_ID="$(aws_json ec2 create-security-group --group-name "$DB_GROUP_NAME" \
    --description "Private PostgreSQL for W5" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_specs security-group "$DB_GROUP_NAME" "$COURSE" "$WEEK" "$GROUP" "$OWNER")" \
    --query 'GroupId' | python3 -c 'import json,sys; print(json.load(sys.stdin))')"
  save_record "w05.db_security_group" \
    "$(python3 -c 'import json,sys,datetime;print(json.dumps({"id":sys.argv[1],"created_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$DB_SG_ID")"
  note "Created DB security group $DB_SG_ID; ID saved."
fi

DB_SG_RULES="$(aws_json ec2 describe-security-groups --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,Groups:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}')"
python3 - "$DB_SG_RULES" "$HOST_SG_ID" <<'PY'
import json, sys
rules = json.loads(sys.argv[1])
if len(rules) not in (0, 1):
    raise SystemExit("STOP: DB SG must have exactly one ingress rule.")
if not rules:
    raise SystemExit(0)
rule = rules[0]
if (rule.get("Proto") != "tcp" or rule.get("From") != 5432 or
        rule.get("To") != 5432 or rule.get("Groups") != [sys.argv[2]] or
        rule.get("CIDRs")):
    raise SystemExit("STOP: DB SG ingress readback does not match TCP 5432 from the EC2 SG only.")
PY
if [[ "$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$DB_SG_RULES")" == "0" ]]; then
  aws_json ec2 authorize-security-group-ingress --group-id "$DB_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$HOST_SG_ID}]" >/dev/null
fi
DB_SG_RULES="$(aws_json ec2 describe-security-groups --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,Groups:UserIdGroupPairs[].GroupId,CIDRs:IpRanges[].CidrIp}')"
python3 - "$DB_SG_RULES" "$HOST_SG_ID" <<'PY'
import json, sys
rules = json.loads(sys.argv[1])
if len(rules) != 1:
    raise SystemExit("STOP: DB SG must have exactly one ingress rule.")
rule = rules[0]
if (rule.get("Proto") != "tcp" or rule.get("From") != 5432 or
        rule.get("To") != 5432 or rule.get("Groups") != [sys.argv[2]] or
        rule.get("CIDRs")):
    raise SystemExit("STOP: DB SG ingress readback does not match TCP 5432 from the EC2 SG only.")
PY

REQUEST_FILE="$(mktemp .local/.db-create-request.XXXXXX.json)"
chmod 600 "$REQUEST_FILE"
python3 - "$REQUEST_FILE" "$DB_ENV" "$DB_IDENTIFIER" "$DB_SUBNET_GROUP" "$DB_SG_ID" \
  "$DB_USER" "$COURSE" "$WEEK" "$GROUP" "$OWNER" <<'PY'
import json, os, secrets, string, sys
request_path, env_path, identifier, subnet_group, security_group, user, course, week, group, owner = sys.argv[1:]
alphabet = string.ascii_letters + string.digits
password = "".join(secrets.choice(alphabet) for _ in range(32))
fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    stream.write("DB_NAME=inspection\nDB_USER=" + user + "\nDB_PASSWORD=" + password + "\n")
request = {
    "DBInstanceIdentifier": identifier,
    "DBInstanceClass": "db.t3.micro",
    "Engine": "postgres",
    "MasterUsername": user,
    "MasterUserPassword": password,
    "AllocatedStorage": 20,
    "StorageType": "gp3",
    "StorageEncrypted": True,
    "PubliclyAccessible": False,
    "MultiAZ": False,
    "DBName": "inspection",
    "DBSubnetGroupName": subnet_group,
    "VpcSecurityGroupIds": [security_group],
    "Tags": [
        {"Key": "course", "Value": course},
        {"Key": "week", "Value": week},
        {"Key": "group", "Value": group},
        {"Key": "owner", "Value": owner},
    ],
}
with open(request_path, "w", encoding="utf-8") as stream:
    os.chmod(request_path, 0o600)
    json.dump(request, stream)
PY

note "Creating RDS instance $DB_IDENTIFIER; password is stored only in $DB_ENV (600), never displayed."
aws_json rds create-db-instance --cli-input-json "file://$REQUEST_FILE" \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Public:PubliclyAccessible}' >/dev/null
rm -f -- "$REQUEST_FILE"
REQUEST_FILE=""
save_record "w05.rds" \
  "$(python3 -c 'import json,sys,datetime;print(json.dumps({"identifier":sys.argv[1],"created_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$DB_IDENTIFIER")"
note "RDS identifier recorded in $RESOURCES. Waiting for status available..."

DB_INFO=""
for _ in $(seq 1 120); do
  DB_INFO="$(aws_json rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
    --query 'DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Public:PubliclyAccessible,Address:Endpoint.Address,Port:Endpoint.Port,Encrypted:StorageEncrypted,Class:DBInstanceClass,Storage:AllocatedStorage,StorageType:StorageType,MultiAZ:MultiAZ}')"
  STATUS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Status"])' "$DB_INFO")"
  note "  RDS status: $STATUS"
  [[ "$STATUS" == "available" ]] && break
  sleep 30
done
[[ "${STATUS:-}" == "available" ]] || stop "RDS did not become available within 60 minutes. Do not rerun; inspect the recorded identifier."

python3 - "$DB_INFO" "$DB_ENV" <<'PY'
import json, os, pathlib, sys, tempfile
info = json.loads(sys.argv[1])
if info.get("Public") is not False or info.get("Encrypted") is not True:
    raise SystemExit("STOP: RDS public/encryption readback did not meet the contract.")
if info.get("Class") != "db.t3.micro" or info.get("Storage") != 20 or info.get("StorageType") != "gp3" or info.get("MultiAZ") is not False:
    raise SystemExit("STOP: RDS configuration readback did not meet the contract.")
path = pathlib.Path(sys.argv[2])
lines = path.read_text(encoding="utf-8").splitlines()
values = dict(line.split("=", 1) for line in lines if "=" in line)
values["DB_HOST"] = info["Address"]
values["DB_PORT"] = str(info["Port"])
fd, temporary = tempfile.mkstemp(prefix=".db-env-", dir=path.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        for key in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"):
            stream.write(key + "=" + values[key] + "\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

save_record "w05.rds_endpoint" \
  "$(python3 -c 'import json,sys;print(json.dumps({"address":json.loads(sys.argv[1])["Address"],"port":json.loads(sys.argv[1])["Port"]}))' "$DB_INFO")"
note ""
note "== Final readback =="
note "RDS $DB_IDENTIFIER: status=available, PubliclyAccessible=false, encrypted=true, class=db.t3.micro, storage=20 GiB gp3, MultiAZ=false"
note "Endpoint saved privately in $DB_ENV; DB password remains hidden."
note "W5 resource IDs and metadata are recorded in $RESOURCES."
