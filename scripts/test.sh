#!/bin/bash
# Run every automated test: OfferlaneCore unit + integration tests, then UI tests.
# Usage: scripts/test.sh [core|ui|apply|real|all]
#   apply: in-app apply engine against the bundled mock sites (WebKit needs the app process)
#   real:  real-site smoke tests (Greenhouse, Lever, Ashby, Workday); nothing is submitted, no accounts created
set -euo pipefail
cd "$(dirname "$0")/.."
WHAT="${1:-all}"
if [[ "$WHAT" == core || "$WHAT" == all ]]; then
  (cd Packages/OfferlaneCore && swift test 2>&1 | tail -n 30)
fi
if [[ "$WHAT" == ui || "$WHAT" == all ]]; then
  command -v xcodegen >/dev/null && xcodegen generate --quiet
  xcodebuild -project Offerlane.xcodeproj -scheme Offerlane -derivedDataPath build/DerivedData -skipPackagePluginValidation \
    -destination 'platform=macOS' test -quiet
fi
APP="build/DerivedData/Build/Products/Debug/Offerlane.app/Contents/MacOS/Offerlane"
selftest() {  # $1 = apply | real
  [[ -x "$APP" ]] || scripts/build.sh Debug >/dev/null
  local home; home="$(mktemp -d)"
  env OFFERLANE_HOME="$home" OFFERLANE_FAKE_AI=1 OFFERLANE_ONBOARDED=1 OFFERLANE_SELFTEST="$1" "$APP" 2>/dev/null | grep -E "PASS|FAIL|SMOKE|answers|simple form"
  local code=${PIPESTATUS[0]}; rm -rf "$home"; return "$code"
}
if [[ "$WHAT" == apply || "$WHAT" == all ]]; then selftest apply; fi
if [[ "$WHAT" == real ]]; then selftest real; fi
echo "Tests finished."
