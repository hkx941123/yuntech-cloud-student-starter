#!/usr/bin/env python3
"""Check tracked file hygiene and local links without printing sensitive matching content."""
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]


def main():
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    errors = []
    for name in filter(None, names):
        path = ROOT / name
        if re.search(r"(^|/)(credentials|\.env(?:\..*)?|\.aws|\.local|\.terraform)(/|$)|\.tfstate(?:\.|$)|\.tfplan(?:\.|$)|\.tfvars(?:\.json)?$|\.(pem|key)$", name):
            errors.append(f"Forbidden tracked path: {name}")
        if not path.is_file():
            continue
        if path.suffix.lower() in ('.png', '.jpg', '.jpeg'):
            signature = b'\x89PNG\r\n\x1a\n' if path.suffix.lower() == '.png' else b'\xff\xd8\xff'
            if not path.read_bytes().startswith(signature):
                errors.append(f'Invalid image signature: {name}')
            # Screenshots are reviewed visually before commit; text regex scans
            # cannot certify that a bitmap contains no credentials.
            continue
        text = path.read_text(encoding="utf-8")
        if re.search(r"(?:AKIA|ASIA)[A-Z0-9]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text):
            errors.append(f"Possible secret in {name}; inspect privately")
        if path.suffix == ".json":
            json.loads(text)
        # Upstream references sometimes deliberately route to skills outside this subset.
        if path.suffix == ".md" and not name.startswith((".agents/", "third-party/")):
            for target in re.findall(r"(?<!!)\[[^\]]*\]\(([^\s)]+)\)", text):
                target = unquote(target.split("#")[0])
                if not target or "://" in target or target.startswith("mailto:"):
                    continue
                if not (path.parent / target).exists():
                    errors.append(f"Broken local link in {name}: {target}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Tracked file hygiene, JSON and local documentation links passed (heuristic scan, not a secret-vault guarantee).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
