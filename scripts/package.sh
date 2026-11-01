#!/bin/bash
# Builds the installers you ship:
#   dist/Offerlane-<version>.dmg   drag-to-Applications disk image
#   dist/Offerlane-<version>.pkg   double-click installer (installs into /Applications)
#   dist/SHA256SUMS.txt
# Signs ad-hoc unless DEVELOPER_ID="Developer ID Application: …" is set (and INSTALLER_ID="Developer ID Installer: …"
# for the .pkg). Notarizes both when NOTARY_PROFILE is set (create one with: xcrun notarytool store-credentials <profile>).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Release
APP_SRC="build/DerivedData/Build/Products/Release/Offerlane.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_SRC/Contents/Info.plist")
rm -rf dist; mkdir -p dist
APP="dist/Offerlane.app"; cp -R "$APP_SRC" "$APP"

# Privacy gate: never ship a binary that carries the build machine's home folder or username.
if strings -a "$APP/Contents/MacOS/Offerlane" | grep -q "/Users/"; then
  echo "error: the app binary contains a /Users/ path; refusing to package" >&2; exit 1
fi

IDENTITY="${DEVELOPER_ID:--}"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Disk image with an Applications shortcut.
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Offerlane $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Offerlane-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

# Installer package.
PKGROOT="$(mktemp -d)"; mkdir -p "$PKGROOT/Applications"; cp -R "$APP" "$PKGROOT/Applications/"
pkgbuild --root "$PKGROOT" --identifier com.somilmanke.Offerlane.pkg --version "$VERSION" --install-location / \
  ${INSTALLER_ID:+--sign "$INSTALLER_ID"} "dist/Offerlane-$VERSION.pkg" >/dev/null
rm -rf "$PKGROOT"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  codesign --sign "$IDENTITY" "dist/Offerlane-$VERSION.dmg"
  for f in "dist/Offerlane-$VERSION.dmg" "dist/Offerlane-$VERSION.pkg"; do
    xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait && xcrun stapler staple "$f"
  done
fi
(cd dist && shasum -a 256 "Offerlane-$VERSION.dmg" "Offerlane-$VERSION.pkg" > SHA256SUMS.txt)
lipo -archs "$APP/Contents/MacOS/Offerlane"
echo "Packaged: dist/Offerlane-$VERSION.dmg, dist/Offerlane-$VERSION.pkg"
