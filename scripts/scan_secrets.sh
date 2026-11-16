#!/bin/bash
# git-secrets-style scan of the working tree and the FULL history (every commit, every branch).
# Allowed: documented placeholders and the fake keys used by tests.
set -euo pipefail
cd "$(dirname "$0")/.."
re='sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|1//0[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|GOCSPX-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
allow='sk-ant-api03-AbCdEf|REPLACE_WITH|BEGIN RSA PRIVATE KEY-----"\)|TestSigner'
hits_tree=$(git grep -nIE "$re" -- . ':!*.png' 2>/dev/null | grep -vE "$allow" || true)
hits_hist=$(git log --all -p --no-color 2>/dev/null | grep -nE "^\+.*($re)" | grep -vE "$allow" || true)
files_hist=$(git log --all --name-only --pretty=format: | sort -u | grep -iE "\.(sqlite|db|p12|pem|key|keychain|mobileprovision)$|(^|/)\.env|Fixtures/private/" || true)
status=0
[[ -z "$hits_tree" ]] || { echo "secret-like strings in the working tree:"; echo "$hits_tree" | cut -c1-160; status=1; }
[[ -z "$hits_hist" ]] || { echo "secret-like strings in git history:"; echo "$hits_hist" | cut -c1-160; status=1; }
[[ -z "$files_hist" ]] || { echo "sensitive files were committed at some point:"; echo "$files_hist"; status=1; }
[[ $status -eq 0 ]] && echo "secret scan: clean ($(git rev-list --all | wc -l | tr -d ' ') commits)"
exit $status
