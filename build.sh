#!/bin/bash
# Builds Pareto for Mac: one app for Apple silicon and Intel, signed ad hoc, and a
# .dmg to download. Needs only Apple's Command Line Tools, not Xcode.
#
#   ./build.sh            build/Pareto.app and dist/Pareto-<version>.dmg
#   ./build.sh --dev      just the app, for this Mac only, faster
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$(xcrun --show-sdk-path)"
VERSION="$(cat VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
NAME="Pareto"
# The identifier, the ctrlf-meaning:// links and the signing certificate keep the old name on
# purpose: macOS ties the key, settings and permissions to them, so they carry over.
APP="build/$NAME.app"
FLAGS=(-swift-version 5 -O -sdk "$SDK")

rm -rf "$APP" build/icon build/dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "--dev" ]]; then
  swiftc "${FLAGS[@]}" -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/Pareto" Sources/*.swift
else
  for arch in arm64 x86_64; do
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos13.0" -o "build/Pareto-$arch" Sources/*.swift
  done
  lipo -create -output "$APP/Contents/MacOS/Pareto" build/Pareto-arm64 build/Pareto-x86_64
fi

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The typefaces (SIL Open Font License, licences included), registered by the app at launch.
cp -R Resources/Fonts "$APP/Contents/Resources/"

# The icon, drawn by the app itself.
"$APP/Contents/MacOS/Pareto" --icon build/icon/AppIcon.iconset >/dev/null
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Signed with the app's own certificate (signing.sh), so macOS keeps the Accessibility and
# Screen Recording switches across updates. Without it, an ad-hoc signature. Either way a
# download needs Open Anyway once; a Developer ID and notarization (Apple's $99/year
# program) would remove that step.
source ./signing.sh
set -e
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_ID" --identifier com.ctrlf-by-meaning.mac "$APP"
  SIGNED="its own certificate"
else
  codesign --force --deep --sign - --identifier com.ctrlf-by-meaning.mac "$APP"
  SIGNED="ad hoc"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Pareto"), signed with $SIGNED)"

[[ "${1:-}" == "--dev" ]] && exit 0

# The download opens as a window: the app, an arrow to Applications, and the guide
# (READ ME FIRST.pdf, made from dmg/READ ME FIRST.html). dmgbuild lays the window out
# without needing Finder; it's installed once into build/venv, not system-wide.
mkdir -p build/dmg dist
dmg/make.sh "$VERSION" "$PWD/build/dmg" "$PWD/build/icon/AppIcon.iconset/icon_128x128@2x.png"
if [[ ! -x build/venv/bin/dmgbuild ]]; then
  python3 -m venv build/venv
  PIP_DISABLE_PIP_VERSION_CHECK=1 build/venv/bin/pip install --quiet dmgbuild==1.6.7
fi
DMG="dist/Pareto-$VERSION.dmg"
rm -f "$DMG"
build/venv/bin/dmgbuild -s dmg/settings.py \
  -D app="$APP" -D guide="build/dmg/READ ME FIRST.pdf" \
  -D icon="$APP/Contents/Resources/AppIcon.icns" -D background="build/dmg/background.png" \
  "$NAME" "$DMG" 2>&1 >/dev/null | grep -v "is deprecated" >&2 || true
[[ -s "$DMG" ]] || { echo "dmgbuild didn't make $DMG" >&2; exit 1; }
rm -rf build/dmg
echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"
