#!/bin/bash
# Builds PolyMac.app (universal: Apple Silicon + Intel) and a zip ready to attach to a GitHub release.
#
#   scripts/build-app.sh             # dist/PolyMac.app and dist/PolyMac-<version>.zip
#   scripts/build-app.sh --native    # this Mac's architecture only (faster, for trying things out)
#   scripts/build-app.sh --install   # also copy the app to /Applications
#
# The version comes from mac-app/VERSION. Signing is ad-hoc by default, so on other Macs the first
# launch needs right-click → Open. With an Apple Developer ID you can sign and notarize instead:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=polymac scripts/build-app.sh
# (create the profile once with: xcrun notarytool store-credentials polymac)
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$PWD"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="io.github.debberson.polymac"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Notarizing needs a Developer ID: set SIGN_IDENTITY too (see 'security find-identity -v -p codesigning')." >&2
    exit 1
fi

ARCH_FLAGS=(--arch arm64 --arch x86_64)
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --native) ARCH_FLAGS=() ;;
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Build and sign outside the repo: iCloud-synced folders (~/Documents) add extended attributes
# that codesign rejects.
WORK="${TMPDIR:-/tmp}/polymac-app-build"
STAGE="$WORK/stage"
APP="$STAGE/PolyMac.app"
DIST="$APP_DIR/dist"
ZIP="$DIST/PolyMac-$VERSION.zip"

echo "==> Building PolyMac $VERSION ($BUILD_NUMBER), release"
BUILD_FLAGS=(-c release --scratch-path "$WORK/build" -Xswiftc -DPOLYMAC_APP_BUNDLE ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling PolyMac.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PolyMac" "$APP/Contents/MacOS/PolyMac"
strip -S -x "$APP/Contents/MacOS/PolyMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>PolyMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PolyMac</string>
    <key>CFBundleDisplayName</key><string>PolyMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Open source: github.com/debberson/PolyMac</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "$SIGN_IDENTITY"))"
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" != "-" ] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # What a downloader's Mac will decide: should say "accepted, source=Notarized Developer ID".
    spctl --assess --type execute --verbose=2 "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

rm -rf "$DIST/PolyMac.app"
ditto "$APP" "$DIST/PolyMac.app"

if [ "$INSTALL" = 1 ]; then
    echo "==> Installing to /Applications"
    rm -rf /Applications/PolyMac.app
    ditto "$APP" /Applications/PolyMac.app
fi

echo
echo "Built PolyMac $VERSION ($(lipo -archs "$APP/Contents/MacOS/PolyMac"))"
echo "  App: $DIST/PolyMac.app"
echo "  Zip: $ZIP  ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
