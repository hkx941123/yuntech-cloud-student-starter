#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--environment" ]]; then bash .devcontainer/scripts/verify-environment.sh; fi
python3 scripts/install-aws-skills.py --verify
python3 scripts/verify-repo.py
python3 -m unittest discover -s tests -v
for script in scripts/*.sh .devcontainer/scripts/*.sh; do bash -n "$script"; done
if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh .devcontainer/scripts/*.sh; fi
