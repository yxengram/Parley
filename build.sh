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
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP"
