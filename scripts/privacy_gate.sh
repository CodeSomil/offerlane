#!/bin/bash
# Refuses to ship an app bundle (or a DMG) that carries personal data or build-machine details:
#   - absolute home paths (/Users/...), this Mac's user name, the git author's email;
#   - data files that must never ship (databases, keychains, keys, .env, the private test fixtures);
#   - anything that looks like a live secret (API keys, OAuth tokens, private keys).
# Usage: scripts/privacy_gate.sh <path/to/Offerlane.app | path/to/Offerlane.dmg>
set -euo pipefail
TARGET="$1"; MOUNT=""
cleanup() { [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [[ "$TARGET" == *.dmg ]]; then
  MOUNT="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$TARGET" >/dev/null
  extra=$(ls -A "$MOUNT" | grep -vxE "Offerlane.app|Applications|\.background|\.DS_Store|\.fseventsd|\.VolumeIcon\.icns" || true)
  [[ -z "$extra" ]] || { echo "privacy gate: unexpected files in the DMG: $extra" >&2; exit 1; }
  TARGET="$MOUNT/Offerlane.app"
fi
[[ -d "$TARGET" ]] || { echo "privacy gate: $TARGET not found" >&2; exit 1; }
fail=0
report() { echo "privacy gate: $1" >&2; fail=1; }

bad_files=$(find "$TARGET" \( -iname "*.sqlite*" -o -iname "*.db" -o -iname "*.keychain*" -o -iname "*.p12" -o -iname "*.pem" -o -iname "*.key" \
  -o -iname ".env*" -o -iname "accounts.json" -o -path "*/private/*" -o -iname "*.mobileprovision" \) | grep -v "/_CodeSignature/" || true)
[[ -z "$bad_files" ]] || report "files that must not ship: $bad_files"

user="$(id -un)"; email="$(git config user.email 2>/dev/null || true)"
# This Mac's own paths. (Generic "/Users/" also appears in redaction patterns and in third-party build paths such as
# tectonic's "/Users/runner/.cargo", which identify no one.)
patterns=("$HOME" "/Users/$user/" "/Users/$user\"" "/home/$user")
[[ -n "$email" ]] && patterns+=("$email")
secrets='sk-ant-[A-Za-z0-9_-]{20,}|ya29\.[0-9A-Za-z_-]{20,}|1//0[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|GOCSPX-[A-Za-z0-9_-]{20,}'
while IFS= read -r -d '' f; do
  case "$f" in */_CodeSignature/*|*/TectonicCache/*) continue ;; esac
  # Helpers/tectonic is upstream's binary, pinned by SHA-256 in scripts/fetch-tectonic.sh. It carries its own builder's
  # "/Users/runner/..." paths, which match this Mac's home only on a CI runner (user "runner"). It still gets the secret scan.
  if [[ "$f" != */Contents/Helpers/tectonic ]]; then
    for p in "${patterns[@]}"; do
      if LC_ALL=C grep -aqF "$p" "$f"; then report "'$p' found in ${f#$TARGET/}"; fi
    done
  fi
  # OAuthConfig.plist holds the Google *Desktop* client secret, which Google treats as public (docs/GOOGLE_SETUP.md).
  if [[ "$f" == */OAuthConfig.plist ]]; then file_secrets="${secrets//|GOCSPX-\[A-Za-z0-9_-\]\{20,\}/}"; else file_secrets="$secrets"; fi
  if LC_ALL=C grep -aqE "$file_secrets" "$f"; then report "secret-like string in ${f#$TARGET/}"; fi
done < <(find "$TARGET" -type f -print0)
# The user name in a path or address (the bundle ID "com.<name>.Offerlane" is deliberate and allowed).
if LC_ALL=C grep -aqE "(/|~)$user(/|\b)|$user@" "$TARGET/Contents/MacOS/Offerlane"; then report "this Mac's user name '$user' is in a path or address in the app binary"; fi

[[ $fail -eq 0 ]] && echo "privacy gate: clean ($(find "$TARGET" -type f | wc -l | tr -d ' ') files checked)"
exit $fail
