#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Parley.app and zips it for a GitHub release.
#   tools/package_release.sh            -> build/release/Parley-<version>.zip (+ ParleyReader.html, ParleyWeb.html)
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
# The linker leaves debug-map entries in the symbol table: the absolute path of every object file
# and source file, which names this Mac's user and folders. They are only for dsymutil; strip them.
strip -S "$TMP/universal"
cp "$TMP/universal" "$NATIVE"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
lipo -archs "$NATIVE"

# No pipeline: under pipefail `grep -q` exiting early SIGPIPEs `strings` and the check fails open.
if LC_ALL=C grep -qaF PARLEY_SNAPSHOT "$NATIVE"; then
    echo "error: the release binary contains the snapshot harness" >&2
    exit 1
fi
# Every byte of the bundle, not only what `strings` shows: the symbol table is not in its view.
for private in "/Users/" "$HOME" "$USER"; do
    if LC_ALL=C grep -rqaF -- "$private" "$APP"; then
        echo "error: the app contains a local path or the user name ($private)" >&2
        exit 1
    fi
done

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/Parley-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
cp Reader/ParleyReader.html "$OUT/ParleyReader.html"
cp Web/ParleyWeb.html "$OUT/ParleyWeb.html"
# The pages are built from sources in the repository, but check them like the app anyway.
for page in "$OUT/ParleyReader.html" "$OUT/ParleyWeb.html"; do
    for private in "/Users/" "$HOME" "$USER"; do
        if LC_ALL=C grep -qaF -- "$private" "$page"; then
            echo "error: ${page:t} contains a local path or the user name ($private)" >&2
            exit 1
        fi
    done
done

# Check the archive opens to a valid, signed app.
mkdir "$TMP/unzip"
ditto -x -k "$ZIP" "$TMP/unzip"
codesign --verify --deep --strict "$TMP/unzip/Parley.app"

( cd "$OUT" && shasum -a 256 "Parley-$VERSION.zip" ParleyReader.html ParleyWeb.html )
