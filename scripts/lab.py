#!/usr/bin/env python3
import argparse

import configparser

import getpass

import hashlib

import io

import json

import os

from pathlib import Path

import re

import subprocess

import sys

import tempfile

import urllib.error

import urllib.request

import time

ROOT = Path(__file__).resolve().parents[1]

COURSE = "yuntech-115-1"

PROFILE = "learnerlab"

class LabError(Exception):
    pass

def aws_dir():
    return Path.home() / ".aws"

def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.parent.is_symlink():
        raise LabError("Refusing a symlink for credential/context storage.")
    fd, name = tempfile.mkstemp(prefix=".lab-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.chmod(name, 0o600)
            stream.write(content)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def profile_update(path, section, values):
    parser = configparser.RawConfigParser()
    parser.read(path, encoding="utf-8")
    # Replace only the course section, removing stale role/credential_process settings.
    parser.remove_section(section)
    if values is not None:
        parser[section] = values
    buf = io.StringIO()
    parser.write(buf)
    atomic_write(path, buf.getvalue())

def clean_env(region, credentials=None, config=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("AWS_", "TF_VAR_", "TF_CLI_ARGS", "TF_LOG"))}
    env.update(AWS_PROFILE=PROFILE, AWS_REGION=region, AWS_DEFAULT_REGION=region,
               AWS_SHARED_CREDENTIALS_FILE=str(credentials or aws_dir() / "credentials"),
               AWS_CONFIG_FILE=str(config or aws_dir() / "config"), AWS_PAGER="",
               AWS_EC2_METADATA_DISABLED="true", AWS_CLI_AUTO_PROMPT="off")
    return env

def error_code(stderr):
    match = re.search(r"An error occurred \(([A-Za-z0-9._-]+)\)", stderr)
    if match:
        return match.group(1)
    if "credentials" in stderr.lower():
        return "CredentialsUnavailable"
    return "CommandFailed"

def run_aws(args, region, env=None, raw=False):
    command = ["aws", "--profile", PROFILE, "--region", region, "--no-cli-pager", *args]
    if not raw:
        command.extend(["--output", "json"])
    try:
        result = subprocess.run(command, env=env or clean_env(region), capture_output=True,
                                text=True, timeout=90, check=False)
    except FileNotFoundError as exc:
        raise LabError("AWS CLI missing; open the devcontainer.") from exc
    except subprocess.TimeoutExpired as exc:
        raise LabError("AWS request timed out; check connection and inspect before retrying a write.") from exc
    if result.returncode:
        code = error_code(result.stderr)
        # Raw stderr/debug traces can contain signed URLs or supplied input. Never echo them.
        raise LabError(f"{args[0]} {args[1]}: {code}. Stop; check session, region and Academy policy. Do not modify IAM.")
    return result.stdout.strip() if raw else json.loads(result.stdout or "{}")

def context():
    path = aws_dir() / "learnerlab-context.json"
    if not path.exists():
        raise LabError("Run scripts/set-learnerlab-credentials.sh in your terminal first.")
    ctx = json.loads(path.read_text())
    if not re.fullmatch(r"\d{12}", ctx.get("account", "")) or ctx.get("region") not in ("us-east-1", "us-west-2"):
        raise LabError("Invalid course context; reconfigure Learner Lab.")
    return ctx

def verify(ctx=None):
    ctx = ctx or context()
    identity = run_aws(["sts", "get-caller-identity"], ctx["region"])
    if identity.get("Account") != ctx["account"]:
        raise LabError("Account mismatch: refusing operations. Reconfigure and compare with the Learner Lab console.")
    if ":assumed-role/" not in identity.get("Arn", ""):
        raise LabError("Expected temporary assumed-role credentials from Learner Lab.")
    print(f"Identity OK: account ending {ctx['account'][-4:]}, region {ctx['region']}, profile learnerlab")
    return ctx

def configure():
    if not sys.stdin.isatty():
        raise LabError("Credential entry requires your interactive terminal; never pass secrets as command arguments or chat.")
    region = input("Region [us-east-1]: ").strip() or "us-east-1"
    if region not in ("us-east-1", "us-west-2"):
        raise LabError("This course currently allows only us-east-1/us-west-2; teacher must verify your Lab region.")
    account = input("12-digit account ID shown in YOUR Learner Lab console: ").strip()
    if not re.fullmatch(r"\d{12}", account):
        raise LabError("Invalid account ID.")
    values = {key: getpass.getpass(label + ": ").strip() for key, label in (
        ("aws_access_key_id", "Access key ID (hidden)"),
        ("aws_secret_access_key", "Secret access key (hidden)"),
        ("aws_session_token", "Session token (hidden)"))}
    if any(not v or any(ch.isspace() for ch in v) for v in values.values()):
        raise LabError("Paste each VALUE only, without labels, quotes, or whitespace.")
    # Verify before overwriting a working profile. Temporary files stay outside the repository.
    with tempfile.TemporaryDirectory(prefix="learnerlab-", dir=Path.home()) as td:
        cred, cfg = Path(td) / "credentials", Path(td) / "config"
        profile_update(cred, PROFILE, values)
        profile_update(cfg, "profile learnerlab", {"region": region, "output": "json"})
        identity = run_aws(["sts", "get-caller-identity"], region, clean_env(region, cred, cfg))
        if identity.get("Account") != account or ":assumed-role/" not in identity.get("Arn", ""):
            raise LabError("Credentials do not match the supplied Learner Lab account/assumed role. Nothing saved.")
    profile_update(aws_dir() / "credentials", PROFILE, values)
    profile_update(aws_dir() / "config", "profile learnerlab", {"region": region, "output": "json"})
    atomic_write(aws_dir() / "learnerlab-context.json", json.dumps({"account": account, "region": region}))
    print("Verified and saved learnerlab profile outside the repo. Restart optional MCP after every credential refresh.")

def clear():
    for filename, section in (("credentials", PROFILE), ("config", "profile learnerlab")):
        path = aws_dir() / filename
        if path.exists():
            profile_update(path, section, None)
    (aws_dir() / "learnerlab-context.json").unlink(missing_ok=True)
    print("Removed only learnerlab profile/context. This does not revoke STS credentials or delete AWS resources.")

def approve(description, token):
    print(description)
    if not sys.stdin.isatty():
        raise LabError("No interactive approval. Have the student execute the reviewed command in their own terminal.")
    if input(f"Type exactly {token} to proceed: ").strip() != token:
        raise LabError("Cancelled; no changes made.")

def inventory():
    ctx = verify()
    queries = [
        ("EC2", ["ec2", "describe-instances", "--query", "Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}"]),
        ("S3", ["s3api", "list-buckets", "--query", "Buckets[].Name"]),
        ("RDS", ["rds", "describe-db-instances", "--query", "DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Public:PubliclyAccessible}"]),
        ("VPC", ["ec2", "describe-vpcs", "--query", "Vpcs[].{Id:VpcId,CIDR:CidrBlock}"]),
        ("SecurityGroups", ["ec2", "describe-security-groups", "--query", "SecurityGroups[].{Id:GroupId,VPC:VpcId,Name:GroupName}"])]
    failed = False
    for label, args in queries:
        print(f"$ aws --profile learnerlab --region {ctx['region']} {' '.join(args[:2])} [bounded projection]")
        try:
            print(json.dumps({label: run_aws(args, ctx["region"])}, indent=2))
        except LabError as exc:
            print(str(exc))
            failed = True
    if failed:
        raise LabError("Inventory incomplete: one or more read operations failed; no remediation was attempted.")

def main():
    parser = argparse.ArgumentParser(description="Credential and read-only course helpers")
    parser.add_argument('command', choices=['configure', 'clear', 'verify', 'inventory'])
    args = parser.parse_args()
    try:
        {'configure': configure, 'clear': clear, 'verify': verify, 'inventory': inventory}[args.command]()
    except (LabError, OSError, ValueError, configparser.Error, EOFError, KeyboardInterrupt) as exc:
        print('STOP: ' + (str(exc) if isinstance(exc, LabError) else type(exc).__name__), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
