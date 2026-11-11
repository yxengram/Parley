#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Parley.app and zips it for a GitHub release.
#   tools/package_release.sh            -> build/release/Parley-<version>.zip (+ ParleyReader.html)
# The app is ad-hoc signed, not notarized: the README explains how to open it the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
OUT="build/release"
APP="build/Parley.app"

./build.sh release                     # native slice, resources, SDK stamp
NATIVE="$APP/Contents/MacOS/Parley"
case "$(uname -m)" in
    arm64) OTHER=x86_64 ;;
    *) OTHER=arm64 ;;
esac

swift build -c release --product Parley --triple "$OTHER-apple-macosx14.0"
OTHER_BIN="$(swift build -c release --triple "$OTHER-apple-macosx14.0" --show-bin-path)/Parley"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parley-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SDK_VERSION="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$TMP/other" "$OTHER_BIN"
lipo -create "$NATIVE" "$TMP/other" -output "$TMP/universal"
cp "$TMP/universal" "$NATIVE"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
lipo -archs "$NATIVE"

if strings "$NATIVE" | grep -q PARLEY_SNAPSHOT; then
    echo "error: the release binary contains the snapshot harness" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/Parley-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
cp Reader/ParleyReader.html "$OUT/ParleyReader.html"

# Check the archive opens to a valid, signed app.
mkdir "$TMP/unzip"
ditto -x -k "$ZIP" "$TMP/unzip"
codesign --verify --deep --strict "$TMP/unzip/Parley.app"

( cd "$OUT" && shasum -a 256 "Parley-$VERSION.zip" ParleyReader.html )
