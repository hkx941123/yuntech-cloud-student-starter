#!/usr/bin/env bash
set -euo pipefail
aws --version
git --version
gh --version
python --version
node --version
java --version
uv --version
uvx --version
jq --version
curl --version
opencode --version
test "$(opencode --version)" = '1.18.30'
test -x /usr/sbin/sshd
/usr/sbin/sshd -V
aws --version 2>&1 | grep -q 'aws-cli/2\.'
node -e 'if (+process.versions.node.split(".")[0] !== 24) process.exit(1)'
java --version | head -n 1 | grep -Eq '(^| )21[. ]'
printf 'Environment check passed. This does not test AWS credentials.\n'
