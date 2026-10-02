#!/bin/bash
# Builds build/Transcriber.app (Developer ID signed, hardened runtime). Usage: ./build_app.sh [version]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(cat VERSION)}"
BUILD="$(date +%Y%m%d%H%M)"
IDENTITY="${SIGN_IDENTITY:-CD882049F8DD5836221DBE167F30CAE12EBB5694}"  # Developer ID Application: Roses as Humans LLC (two certs share the name, so use the hash)
APP="build/Transcriber.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Transcriber"
SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' | head -n 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transcriber"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
cp Support/icon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/; s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"

# Sign inside-out: Sparkle's helpers, the framework, then the app.
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$S/XPCServices/"*.xpc "$S/Updater.app" "$S/Autoupdate" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$item" ] && codesign -f -s "$IDENTITY" -o runtime "$item"
done
codesign -f -s "$IDENTITY" -o runtime --entitlements Support/Transcriber.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
