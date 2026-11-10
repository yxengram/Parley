#!/bin/zsh
# Builds the offline reader: one self-contained HTML file that opens Parley conversation files.
#
#   tools/build_reader.sh [OUTPUT]        (default: Reader/ParleyReader.html)
#
# - downscales the hideout art with sips into a temporary folder (fort pictures 640 px wide,
#   doors 400 px, JPEG quality 70) and inlines it as data: URLs
# - inlines Reader/src/core.js and Reader/src/markdown.js into Reader/src/reader.html
# - refuses a script that could end its <script> element early
# No network, no packages: zsh, sips, python3 (standard library only).
# The output is deterministic: the same sources give the same bytes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Reader/ParleyReader.html}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parley-reader-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ART="$ROOT/Resources/Art"
for src in "$ART"/fort-*.jpg "$ART"/door-*.jpg; do
    name="${src:t:r}"
    case "$name" in
        fort-*) width=640 ;;
        door-*) width=400 ;;
    esac
    sips -s format jpeg -s formatOptions 70 --resampleWidth "$width" "$src" --out "$TMP/$name.jpg" >/dev/null
done

python3 -I - "$ROOT" "$TMP" "$OUT" <<'PY'
import base64, json, pathlib, re, sys

root, art_dir, out = (pathlib.Path(p) for p in sys.argv[1:4])
src = root / 'Reader' / 'src'
template = (src / 'reader.html').read_text(encoding='utf-8')
scripts = {
    '/*@@PARLEY_CORE@@*/': (src / 'core.js').read_text(encoding='utf-8'),
    '/*@@PARLEY_MARKDOWN@@*/': (src / 'markdown.js').read_text(encoding='utf-8'),
}

art = {}
for path in sorted(art_dir.glob('*.jpg')):
    art[path.stem] = 'data:image/jpeg;base64,' + base64.b64encode(path.read_bytes()).decode('ascii')
if len(art) != 12:
    sys.exit(f'build_reader: expected 12 pictures, found {len(art)}')
scripts['/*@@PARLEY_ART@@*/'] = 'window.PARLEY_ART = ' + json.dumps(art, sort_keys=True, separators=(',', ':')) + ';'

for marker, code in scripts.items():
    # Inside <script>, "</script" ends the element and "<!--" changes how the parser reads on.
    if re.search(r'</script|<!--', code, re.I):
        sys.exit(f'build_reader: the code for {marker} contains </script or <!--')
    if template.count(marker) != 1:
        sys.exit(f'build_reader: placeholder {marker} must appear exactly once in reader.html')
    template = template.replace(marker, code)  # plain replace: backslashes in the code stay as they are
if '/*@@' in template:
    sys.exit('build_reader: an unknown placeholder is left in reader.html')

out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(template.encode('utf-8'))
size = out.stat().st_size
print(f'built {out} ({size:,} bytes, {size / 1024:.0f} KB; pictures {sum(len(v) for v in art.values()) / 1024:.0f} KB)')
PY
