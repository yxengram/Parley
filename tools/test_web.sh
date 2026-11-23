#!/bin/zsh
# Tests Parley Web (Web/).
#
#   tools/test_web.sh
#
# 1. node tools/test_web_chat.mjs, test_web_context.mjs, test_web_store.mjs: the JS ports, checked
#    against vectors the Swift app wrote (Web/tests/vectors, Tests/ParleyCoreTests/WebOracleTests.swift)
#    and against tools/mock_server.py.
# 2. node tools/web_fixtures.mjs writes plain and encrypted conversation files with the JS code, and
#    swift test --filter readWebFixtures opens them with the app's own code.
# 3. Builds the page twice into a temporary folder, checks the builds are identical, and runs
#    node tools/test_web_page.mjs on it (CSP, network only in chat.js, no markup from strings, i18n).
# Nothing is written into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parley-web-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"

for name in chat context store; do
    echo "== $name"
    node "tools/test_web_$name.mjs"
done

echo "== files open in Parley (swift test --filter readWebFixtures)"
node tools/web_fixtures.mjs "$TMP/fixtures"
PARLEY_WEB_FIXTURES="$TMP/fixtures" swift test --filter readWebFixtures 2>&1 | tail -n 3
if ! PARLEY_WEB_FIXTURES="$TMP/fixtures" swift test --skip-build --filter readWebFixtures 2>&1 | grep -q "passed"; then
    echo "test_web: the Swift cross-check did not pass" >&2
    exit 1
fi

echo "== page"
tools/build_web.sh "$TMP/a/ParleyWeb.html"
tools/build_web.sh "$TMP/b/ParleyWeb.html" >/dev/null
if ! cmp -s "$TMP/a/ParleyWeb.html" "$TMP/b/ParleyWeb.html"; then
    echo "test_web: two builds differ" >&2
    exit 1
fi
echo "two builds are identical"
node tools/test_web_page.mjs "$TMP/a/ParleyWeb.html"
echo "web: all tests passed"
