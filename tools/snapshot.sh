#!/bin/zsh
# Renders PNG snapshots of Parley's main UI states (light and dark) with the debug-only
# snapshot harness (Sources/Parley/Debug/SnapshotHarness.swift).
#
#   tools/snapshot.sh OUTPUT_DIR
#   PARLEY_SNAPSHOT_LANG=zh-Hans tools/snapshot.sh OUTPUT_DIR     (the whole run in Chinese)
#
# - builds the debug app (./build.sh debug)
# - starts tools/mock_server.py on a free 127.0.0.1 port (killed afterwards)
# - runs the app binary with PARLEY_SNAPSHOT_DIR / PARLEY_SNAPSHOT_MOCK_URL; it never activates,
#   keeps its windows off-screen at alpha 0, and exits on its own (killed after 600 s otherwise)
# - a second mock (flavor strata-share, no API key) backs the Strata states; MOCK_STRATA_PROGRESS=1
#   makes it send prompt progress (as Strata's engine does; the live share port sends none) so the
#   "Reading the prompt" state can be captured
# - PARLEY_SNAPSHOT_MCP_COMMAND points at tools/mock_mcp_server.py, which the app starts on stdio
#   for the MCP states; its secrets stay in memory, so no Keychain item is touched
# - checks that the user's real settings, conversations and saved state were not touched
# - PARLEY_SNAPSHOT_LANG (e.g. zh-Hans, en) runs the app with -AppleLanguages '(LANG)' and
#   -AppleLocale (PARLEY_SNAPSHOT_LOCALE, default zh_CN for zh-Hans, en_US for en); without it the
#   app uses the system's languages. OUTPUT_DIR/missing-strings.txt lists the keys looked up through
#   NSBundle (String(localized:), alerts, dialogs) without a translation for the interface language.
#   PARLEY_SNAPSHOT_SHOW_MISSING=1 adds -NSShowNonLocalizedStrings YES: every string without a
#   translation, SwiftUI Text included, is drawn in CAPITALS in the PNGs.
#
# The binary runs from a temporary copy of the bundle with the identifier
# local.parley.chat.snapshot, so even a write that bypassed the harness's UserDefaults
# redirect could never land in the real domain local.parley.chat.
set -euo pipefail
setopt null_glob

if [[ $# -lt 1 || -z "$1" ]]; then
    echo "usage: $0 OUTPUT_DIR" >&2
    exit 64
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT"/[0-9][0-9]-*.png "$OUT"/[0-9][0-9][0-9]-*.png "$OUT"/snapshot-log.txt "$OUT"/missing-strings.txt

# Interface language: the argument domain is process-wide, so the harness's UserDefaults redirect
# (a different suite for UserDefaults.standard) does not hide it.
LANG_ARGS=()
if [[ -n "${PARLEY_SNAPSHOT_LANG:-}" ]]; then
    case "$PARLEY_SNAPSHOT_LANG" in
        zh-Hans*) DEFAULT_LOCALE=zh_CN ;;
        en*) DEFAULT_LOCALE=en_US ;;
        *) DEFAULT_LOCALE="${PARLEY_SNAPSHOT_LANG//-/_}" ;;
    esac
    LANG_ARGS=(-AppleLanguages "($PARLEY_SNAPSHOT_LANG)" -AppleLocale "${PARLEY_SNAPSHOT_LOCALE:-$DEFAULT_LOCALE}")
    echo "==> Interface language $PARLEY_SNAPSHOT_LANG, locale ${PARLEY_SNAPSHOT_LOCALE:-$DEFAULT_LOCALE}"
fi
if [[ -n "${PARLEY_SNAPSHOT_SHOW_MISSING:-}" ]]; then
    LANG_ARGS+=(-NSShowNonLocalizedStrings YES)
    echo "==> Strings without a translation are drawn in CAPITALS"
fi

REAL_PLIST="$HOME/Library/Preferences/local.parley.chat.plist"
SNAP_ID="local.parley.chat.snapshot"
SNAP_PLIST="$HOME/Library/Preferences/$SNAP_ID.plist"
REAL_DATA="$HOME/Library/Application Support/Parley"
SAVED_STATE="$HOME/Library/Saved Application State"

fingerprint() {
    # Metadata and content hash only; nothing is modified.
    local f
    for f in "$REAL_PLIST" "$SAVED_STATE/local.parley.chat.savedState"; do
        if [[ -e "$f" ]]; then
            print -r -- "$f $(stat -f '%m %z' "$f") $( [[ -f "$f" ]] && shasum -a 256 "$f" | cut -d' ' -f1 )"
        else
            print -r -- "$f absent"
        fi
    done
    if [[ -e "$REAL_DATA" ]]; then
        print -r -- "$REAL_DATA $(find "$REAL_DATA" -exec stat -f '%m %z %N' {} + | shasum -a 256 | cut -d' ' -f1)"
    else
        print -r -- "$REAL_DATA absent"
    fi
    ls "$HOME/Library/Preferences" | grep -i parley | grep -v '^parley\.harness\.' || true
}

echo "==> Building debug app"
"$ROOT/build.sh" debug >/dev/null

WORK="$(mktemp -d "${TMPDIR:-/tmp}/parley-snapshot.XXXXXX")"
MOCK_PID=""
STRATA_PID=""
APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
    [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
    [[ -n "$STRATA_PID" ]] && kill "$STRATA_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Bundle copy with its own identifier (see header).
cp -R "$ROOT/build/Parley.app" "$WORK/Parley.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SNAP_ID" "$WORK/Parley.app/Contents/Info.plist"
# Optional: PARLEY_SNAPSHOT_SDK=14.0 restamps the copy with an older SDK version, so AppKit uses
# the pre-macOS 26 design. cacheDisplay does not render Liquid Glass (floating sidebar, glass
# controls), so this shows the layout of those areas; the default run shows the real build.
if [[ -n "${PARLEY_SNAPSHOT_SDK:-}" ]]; then
    vtool -set-build-version macos 14.0 "$PARLEY_SNAPSHOT_SDK" -replace \
        -output "$WORK/Parley.app/Contents/MacOS/Parley" "$WORK/Parley.app/Contents/MacOS/Parley" 2>/dev/null
fi
codesign --force --sign - "$WORK/Parley.app" >/dev/null 2>&1
BIN="$WORK/Parley.app/Contents/MacOS/Parley"

BEFORE="$(fingerprint)"
SNAP_PLIST_EXISTED=0
[[ -e "$SNAP_PLIST" ]] && SNAP_PLIST_EXISTED=1

PORT="$(/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "==> Starting mock server on 127.0.0.1:$PORT"
/usr/bin/python3 -I -u "$ROOT/tools/mock_server.py" "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
for _ in {1..100}; do
    curl -fsS "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/v1/models" >/dev/null || { echo "mock server did not start" >&2; exit 1; }

STRATA_PORT="$(/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
echo "==> Starting Strata mock (shared port) on 127.0.0.1:$STRATA_PORT"
MOCK_STRATA_PROGRESS=1 /usr/bin/python3 -I -u "$ROOT/tools/mock_server.py" "$STRATA_PORT" strata-share >/dev/null 2>&1 &
STRATA_PID=$!
for _ in {1..100}; do
    curl -fsS "http://127.0.0.1:$STRATA_PORT/v1/models" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS "http://127.0.0.1:$STRATA_PORT/v1/models" >/dev/null || { echo "Strata mock did not start" >&2; exit 1; }

echo "==> Running snapshot harness (exits on its own; hard limit 600 s)"
NO_GLASS=""
[[ -n "${PARLEY_SNAPSHOT_SDK:-}" ]] && NO_GLASS=1
PARLEY_SNAPSHOT_DIR="$OUT" PARLEY_SNAPSHOT_MOCK_URL="http://127.0.0.1:$PORT/v1" PARLEY_SNAPSHOT_STRATA_URL="http://127.0.0.1:$STRATA_PORT/v1" \
    PARLEY_SNAPSHOT_MCP_COMMAND="$ROOT/tools/mock_mcp_server.py" PARLEY_SNAPSHOT_NO_GLASS="$NO_GLASS" \
    PARLEY_SNAPSHOT_MISSING_STRINGS=1 "$BIN" "${LANG_ARGS[@]}" 2>"$WORK/stderr.txt" &
APP_PID=$!
STATUS=0
for _ in {1..6000}; do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "harness did not exit within 600 s; killing it" >&2
    kill -9 "$APP_PID" 2>/dev/null || true
    STATUS=1
fi
wait "$APP_PID" 2>/dev/null || STATUS=$?
APP_PID=""
kill "$MOCK_PID" "$STRATA_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
wait "$STRATA_PID" 2>/dev/null || true
MOCK_PID=""
STRATA_PID=""

grep -v -e '^\[snapshot\]' -e '^    ' "$WORK/stderr.txt" | sed 's/^/    app: /' | head -20 || true

# Isolation checks.
sleep 0.5
AFTER="$(fingerprint)"
if [[ "$BEFORE" != "$AFTER" ]]; then
    echo "ERROR: the user's real Parley settings/data/saved state changed during the run:" >&2
    diff <(print -r -- "$BEFORE") <(print -r -- "$AFTER") >&2 || true
    STATUS=2
fi
if [[ $SNAP_PLIST_EXISTED -eq 0 && -e "$SNAP_PLIST" ]]; then
    echo "WARNING: something bypassed the UserDefaults redirect and wrote $SNAP_PLIST; removing it" >&2
    defaults delete "$SNAP_ID" >/dev/null 2>&1 || true
    rm -f "$SNAP_PLIST"
    [[ $STATUS -eq 0 ]] && STATUS=5
fi
rm -rf "$SAVED_STATE/$SNAP_ID.savedState" 2>/dev/null || true

PNGS=("$OUT"/[0-9][0-9]-*.png "$OUT"/[0-9][0-9][0-9]-*.png)
COUNT=${#PNGS}
echo "==> $COUNT PNGs in $OUT (log: $OUT/snapshot-log.txt)"
for f in "${PNGS[@]}"; do print -r -- "    ${f:t}"; done
grep -m1 -o 'languages=.*handLettering=[a-z]*' "$OUT/snapshot-log.txt" 2>/dev/null | sed 's/^/==> /' || true
if [[ -s "$OUT/missing-strings.txt" ]]; then
    echo "==> $(wc -l < "$OUT/missing-strings.txt" | tr -d ' ') strings without a translation for this language: $OUT/missing-strings.txt"
fi
if [[ $COUNT -eq 0 && $STATUS -eq 0 ]]; then STATUS=1; fi
exit $STATUS
