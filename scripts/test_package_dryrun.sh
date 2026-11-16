#!/bin/bash
# Checks scripts/package.sh --dry-run: the signed path prints every signing/notary/appcast step, the unsigned path
# stays ad hoc, and nothing is built or written. Fast (no build); run by scripts/test.sh core.
set -euo pipefail
cd "$(dirname "$0")/.."
before=$(ls dist 2>/dev/null | sort || true)
# Any real build or signing tool that runs fails the test (dry-run must only print).
stub="$(mktemp -d)"; trap 'rm -rf "$stub"' EXIT
for t in xcodebuild xcodegen codesign hdiutil pkgbuild xcrun lipo; do printf '#!/bin/sh\necho "FAIL dry-run ran %s" >&2; exit 97\n' "$t" > "$stub/$t"; chmod +x "$stub/$t"; done
export PATH="$stub:$PATH"
signed=$(DEVELOPER_ID="Developer ID Application: Test (TEAM123456)" INSTALLER_ID="Developer ID Installer: Test (TEAM123456)" \
  NOTARY_PROFILE=offerlane-notary SPARKLE_DOWNLOAD_PREFIX=https://example.com/dl/ scripts/package.sh --dry-run)
adhoc=$(env -u DEVELOPER_ID -u INSTALLER_ID -u NOTARY_PROFILE -u SPARKLE_DOWNLOAD_PREFIX scripts/package.sh --dry-run)
fail=0
need() { grep -qF -- "$2" <<<"$1" || { echo "FAIL dry-run ($3): missing: $2"; fail=1; }; }
never() { ! grep -qF -- "$2" <<<"$1" || { echo "FAIL dry-run ($3): unexpected: $2"; fail=1; }; }
for s in "scripts/build.sh Release" "--options runtime --timestamp --sign Developer ID Application: Test (TEAM123456)" \
         "Sparkle.framework/Versions/B/XPCServices/Installer.xpc" "Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
         "Sparkle.framework/Versions/B/Autoupdate" "Sparkle.framework/Versions/B/Updater.app" \
         "--sign Developer ID Installer: Test (TEAM123456)" "notarytool submit dist/Offerlane-" "--keychain-profile offerlane-notary" \
         "stapler staple dist/Offerlane-" "spctl --assess" "sign_update dist/Offerlane-" "https://example.com/dl/Offerlane-" \
         "privacy_gate.sh dist/Offerlane.app"; do need "$signed" "$s" signed; done
for s in "--timestamp=none --sign -" "privacy_gate.sh dist/Offerlane.app" "note: not notarised"; do need "$adhoc" "$s" ad-hoc; done
for s in notarytool sign_update "Developer ID"; do never "$adhoc" "$s" ad-hoc; done
NOTARY_PROFILE=x scripts/package.sh --dry-run >/dev/null 2>&1 && { echo "FAIL notarising without INSTALLER_ID must be refused"; fail=1; }
[[ "$(ls dist 2>/dev/null | sort || true)" == "$before" ]] || { echo "FAIL dry-run wrote to dist/"; fail=1; }
[[ $fail == 0 ]] && echo "PASS package.sh --dry-run (signed + ad-hoc)"
exit $fail
