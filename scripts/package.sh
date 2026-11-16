#!/bin/bash
# Builds the installers you ship (version comes from project.yml):
#   dist/Offerlane-<version>.dmg   drag-to-Applications disk image
#   dist/Offerlane-<version>.pkg   double-click installer (installs into /Applications)
#   dist/SHA256SUMS.txt            (+ dist/appcast-item.xml when SPARKLE_DOWNLOAD_PREFIX is set)
# Usage: scripts/package.sh [--dry-run]   (--dry-run prints every step and runs nothing; no build, no files)
# Signing, notarisation and the update feed are switched on by environment variables (nothing secret is in this repo):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"   signs the app (hardened runtime, secure timestamp)
#   INSTALLER_ID="Developer ID Installer: Your Name (TEAMID)"     signs the .pkg
#   NOTARY_PROFILE=<profile>   notarises + staples the .dmg and .pkg (create once with:
#                              xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>)
#   SPARKLE_PUBLIC_KEY=<base64> baked into Info.plist (SUPublicEDKey); the app's update check stays off without it
#   SPARKLE_DOWNLOAD_PREFIX=https://…/   where the DMG will be hosted; EdDSA-signs the DMG for the appcast
#   SPARKLE_KEY_FILE=<path>    optional; default is the key `generate_keys` stored in your login Keychain
# Without them the build is signed ad hoc: fine for testing on this Mac, not for giving to others.
set -euo pipefail
cd "$(dirname "$0")/.."
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
run() { if [[ $DRY == 1 ]]; then echo "+ $*"; else "$@"; fi; }
tmpdir() { if [[ $DRY == 1 ]]; then echo "/tmp/offerlane-dry-run"; else mktemp -d; fi; }
# An unsigned .pkg is rejected by notarisation after the DMG is already done; refuse up front.
[[ -n "${NOTARY_PROFILE:-}" && -z "${INSTALLER_ID:-}" ]] && { echo "error: NOTARY_PROFILE needs INSTALLER_ID too (the .pkg must be signed to notarise)" >&2; exit 1; }
# A signing key with the placeholder feed would ship a release whose update check stays off.
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] && grep -q 'SUFeedURL: "https://example.invalid' project.yml; then
  echo "error: SPARKLE_PUBLIC_KEY is set but SUFeedURL in project.yml is still the example.invalid placeholder" >&2; exit 1
fi

IDENTITY="${DEVELOPER_ID:--}"
TIMESTAMP="--timestamp=none"; [[ "$IDENTITY" != "-" ]] && TIMESTAMP="--timestamp"
APP_SRC="build/DerivedData/Build/Products/Release/Offerlane.app"
APP="dist/Offerlane.app"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

run scripts/build.sh Release
if [[ $DRY == 1 ]]; then
  VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
else
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_SRC/Contents/Info.plist")
fi
run rm -rf dist; run mkdir -p dist
run cp -R "$APP_SRC" "$APP"

if [[ $DRY == 0 ]]; then
  # Universal binary (Apple silicon + Intel) or nothing.
  archs=$(lipo -archs "$APP/Contents/MacOS/Offerlane")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "error: app is not universal ($archs)" >&2; exit 1; }
fi

# Privacy gate: never ship personal data, build-machine paths or secrets (every file in the bundle is checked).
run scripts/privacy_gate.sh "$APP"

# Inside-out: the LaTeX helper, Sparkle's helpers (as Sparkle documents), then the app. Hardened runtime everywhere.
sign() { run codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$@"; }
[[ $DRY == 1 || -e "$APP/Contents/Helpers/tectonic" ]] && sign "$APP/Contents/Helpers/tectonic"
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [[ $DRY == 1 || -d "$SP" ]]; then
  sign "$SP/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
  sign "$SP/Versions/B/Autoupdate"
  sign "$SP/Versions/B/Updater.app"
  sign "$SP"
fi
sign "$APP"
run codesign --verify --deep --strict "$APP"
if [[ $DRY == 0 ]]; then
  sig="$(codesign -dv "$APP" 2>&1)"; [[ "$sig" == *runtime* ]] || { echo "error: hardened runtime missing" >&2; exit 1; }
  [[ -z "$(codesign -d --entitlements :- "$APP" 2>/dev/null)" ]] || { echo "error: unexpected entitlements" >&2; exit 1; }
fi

DMG="dist/Offerlane-$VERSION.dmg"; PKG="dist/Offerlane-$VERSION.pkg"
# Disk image with an Applications shortcut.
STAGE="$(tmpdir)"; run cp -R "$APP" "$STAGE/"; run ln -s /Applications "$STAGE/Applications"
run hdiutil create -volname "Offerlane $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
[[ $DRY == 1 ]] || rm -rf "$STAGE"

# Installer package.
PKGROOT="$(tmpdir)"; run mkdir -p "$PKGROOT/Applications"; run cp -R "$APP" "$PKGROOT/Applications/"
run pkgbuild --root "$PKGROOT" --identifier com.somilmanke.Offerlane.pkg --version "$VERSION" --install-location / \
  ${INSTALLER_ID:+--sign "$INSTALLER_ID"} "$PKG"
[[ $DRY == 1 ]] || rm -rf "$PKGROOT"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  run codesign --sign "$IDENTITY" "$DMG"
  for f in "$DMG" "$PKG"; do
    run xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait
    run xcrun stapler staple "$f"
  done
  run xcrun stapler validate "$DMG"
  run spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "note: not notarised (set DEVELOPER_ID, INSTALLER_ID and NOTARY_PROFILE for a release others can open without warnings)"
fi
run scripts/privacy_gate.sh "$DMG"

# Update feed: EdDSA signature of the final (stapled) DMG, as an <item> to paste into docs/appcast.xml.
if [[ -n "${SPARKLE_DOWNLOAD_PREFIX:-}" && "$IDENTITY" != "-" ]]; then
  if [[ $DRY == 1 ]]; then
    echo "+ $SPARKLE_BIN/sign_update $DMG ${SPARKLE_KEY_FILE:+--ed-key-file $SPARKLE_KEY_FILE}"
    echo "+ write dist/appcast-item.xml (url ${SPARKLE_DOWNLOAD_PREFIX}Offerlane-$VERSION.dmg)"
  else
    attrs=$("$SPARKLE_BIN/sign_update" "$DMG" ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"})
    BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
    cat > dist/appcast-item.xml <<XML
    <item>
      <title>Offerlane $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${SPARKLE_DOWNLOAD_PREFIX}Offerlane-$VERSION.dmg" $attrs type="application/octet-stream"/>
    </item>
XML
    echo "Appcast item: dist/appcast-item.xml (paste into docs/appcast.xml and host it at SUFeedURL)"
  fi
fi
[[ $DRY == 1 ]] && { echo "Dry run: nothing was built or written."; exit 0; }
(cd dist && shasum -a 256 "Offerlane-$VERSION.dmg" "Offerlane-$VERSION.pkg" > SHA256SUMS.txt)
lipo -archs "$APP/Contents/MacOS/Offerlane"
echo "Packaged: $DMG, $PKG"
