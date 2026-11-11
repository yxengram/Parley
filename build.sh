#!/bin/zsh
# Builds Parley.app from the SwiftPM package (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Parley
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Parley"
APP="build/Parley.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Parley"
# SwiftPM records the deployment target as the SDK version (sdk 14.0). AppKit/SwiftUI pick the
# current design (macOS 26+ sidebar, toolbar glass, scroll-edge effects) from the linked SDK
# version, so stamp the real SDK version; the minimum OS stays 14.0.
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [[ -n "$SDK_VERSION" ]]; then
    vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
        -output "$APP/Contents/MacOS/Parley" "$APP/Contents/MacOS/Parley"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Art "$APP/Contents/Resources/Art"
# Interface languages: English (development language, and the fallback for every other language)
# and Simplified Chinese. The system picks one from the user's preferred languages.
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done
codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP"
