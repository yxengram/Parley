#!/bin/zsh
# Tests the offline reader (Reader/).
#
#   tools/test_reader.sh
#
# 1. Writes fixtures with Parley's own encoder into a temporary folder
#    (swift test --filter writeReaderFixtures, Tests/ParleyCoreTests/ReaderFixtureTests.swift).
# 2. node tools/test_reader_core.mjs: file parsing and decryption (Reader/src/core.js).
# 3. node tools/test_reader_markdown.mjs: the markdown port and link rules (Reader/src/markdown.js),
#    against vectors from the app's own parser in tools/reader-tests/.
# 4. Builds the page twice into the temporary folder, checks the two builds are identical, and runs
#    node tools/test_reader_page.mjs on it (CSP, no network APIs, no real links, art embedded).
# Nothing is written into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parley-reader-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURES="$TMP/fixtures"
cd "$ROOT"

echo "== fixtures (swift test --filter writeReaderFixtures)"
PARLEY_READER_FIXTURES="$FIXTURES" swift test --filter writeReaderFixtures 2>&1 | tail -n 3
for name in plain encrypted encrypted-600k tampered minimal not-parley future expected; do
    if [[ ! -s "$FIXTURES/$name.json" ]]; then
        echo "test_reader: fixture $name.json was not written (did the filter match the test?)" >&2
        exit 1
    fi
done

echo "== core"
node tools/test_reader_core.mjs "$FIXTURES"

echo "== markdown"
node tools/test_reader_markdown.mjs

echo "== page"
tools/build_reader.sh "$TMP/a/ParleyReader.html"
tools/build_reader.sh "$TMP/b/ParleyReader.html" >/dev/null
if ! cmp -s "$TMP/a/ParleyReader.html" "$TMP/b/ParleyReader.html"; then
    echo "test_reader: two builds differ; the build is not deterministic" >&2
    exit 1
fi
echo "two builds are identical"
node tools/test_reader_page.mjs "$TMP/a/ParleyReader.html"

echo "reader: all tests passed"
