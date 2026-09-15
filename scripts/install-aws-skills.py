#!/usr/bin/env python3
"""Verify the committed AWS Skills snapshot, or restore it from the pinned upstream."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="Offline hash verification; default")
    parser.add_argument("--restore", action="store_true", help="Restore missing vendored files from the pinned commit")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "third-party/aws-skills.lock.json").read_text())
    if args.restore:
        with tempfile.TemporaryDirectory(prefix="aws-skills-") as td:
            subprocess.run(["git", "clone", "--filter=blob:none", "--no-checkout", manifest["repository"], td], check=True)
            subprocess.run(["git", "-C", td, "checkout", "--detach", manifest["commit"]], check=True)
            for name in manifest["skills"]:
                shutil.copytree(Path(td) / "skills/core-skills" / name, ROOT / ".agents/skills" / name, dirs_exist_ok=True)
    errors = []
    expected = manifest["sha256"]
    actual_files = {p.relative_to(ROOT).as_posix() for name in manifest["skills"]
                    for p in (ROOT / ".agents/skills" / name).rglob("*") if p.is_file()}
    if actual_files != set(expected):
        errors.append("Vendored file set differs from the reviewed snapshot")
    for relative, checksum in expected.items():
        path = ROOT / relative
        # Git normalizes CRLF to LF; hash the normalized text.
        if not path.is_file() or hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest() != checksum:
            errors.append(relative)
    if errors:
        raise SystemExit("AWS Skills verification failed: " + ", ".join(errors))
    print(f"Verified {len(manifest['skills'])} AWS skills, {len(expected)} files at {manifest['commit'][:12]}")


if __name__ == "__main__":
    main()
