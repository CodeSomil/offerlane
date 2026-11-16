#!/bin/bash
# Retakes the README screenshots with demo data (no personal data): runs the UI tests that attach them,
# then copies the named attachments into docs/screenshots/<name>.png. Review the images before committing.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate --quiet
OUT=$(mktemp -d); RESULT="$OUT/run.xcresult"
TEST_RUNNER_OFFERLANE_SCREENSHOTS=1 xcodebuild -project Offerlane.xcodeproj -scheme Offerlane -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -destination 'platform=macOS,arch=arm64' -resultBundlePath "$RESULT" test -quiet \
  -only-testing:OfferlaneUITests/ScreenshotTests -only-testing:OfferlaneUITests/OnboardingTests \
  -only-testing:OfferlaneUITests/ReviewTests -only-testing:OfferlaneUITests/MatchesTests -only-testing:OfferlaneUITests/AuthTests -only-testing:OfferlaneUITests/SetupCenterTests -only-testing:OfferlaneUITests/HelpTourTests
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/raw" >/dev/null
python3 -I - "$OUT/raw" docs/screenshots <<'EOF'
import json, re, shutil, sys
raw, dest = sys.argv[1], sys.argv[2]
keep = re.compile(r'^(readme-.*|welcome-(light|dark)|[1-3]-(ai|resumes|ready)-(light|dark)|review-(light|dark)|review-queue-(light|dark)|key-provider-openrouter-light|setup-center-dark|help-light)$')
n = 0
for t in json.load(open(f"{raw}/manifest.json")):
    for a in t["attachments"]:
        name = re.sub(r'_\d+_[0-9A-F-]+\.png$', '', a.get("suggestedHumanReadableName", ""))
        if a["exportedFileName"].endswith(".png") and keep.match(name):
            shutil.copy(f"{raw}/{a['exportedFileName']}", f"{dest}/{name}.png"); n += 1
print(f"screenshots: {n} copied to {dest}")
EOF
rm -rf "$OUT"
