#!/usr/bin/env bash
set -euo pipefail
# Pin the CLI, including its platform binary; no model call during image build.
version=1.18.30
if ! command -v opencode >/dev/null || [[ "$(opencode --version)" != "$version" ]]; then
  npm install --global --no-audit --no-fund "opencode-ai@$version"
fi
[[ "$(opencode --version)" == "$version" ]]
printf 'OpenCode %s installed. Model availability is checked separately.\n' "$version"
