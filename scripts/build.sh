#!/bin/bash
# Build Offerlane.app. Usage: scripts/build.sh [Debug|Release]   (Release = universal arm64 + x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
command -v xcodegen >/dev/null && xcodegen generate --quiet
[[ -x Vendor/tectonic/bin/tectonic ]] || scripts/fetch-tectonic.sh
xcodebuild -project Offerlane.xcodeproj -scheme Offerlane -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -destination 'generic/platform=macOS' build -quiet
APP="build/DerivedData/Build/Products/$CONFIG/Offerlane.app"
echo "Built: $APP"
