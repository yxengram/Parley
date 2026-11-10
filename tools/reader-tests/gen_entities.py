#!/usr/bin/env python3 -I
"""Rewrites the HTML5 entity table in Reader/src/markdown.js (between the BEGIN/END ENTITIES lines).

cmark, which Foundation's markdown parser is built on, decodes the HTML5 named entities (the ones
with a trailing semicolon). Python's html.entities.html5 is the same list, so the table is generated
from it once and checked in; the page never decodes entities through the DOM.

    python3 -I tools/reader-tests/gen_entities.py
"""
import html.entities
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
path = root / 'Reader' / 'src' / 'markdown.js'
items = sorted((k[:-1], v) for k, v in html.entities.html5.items() if k.endswith(';'))
table = ';'.join(k + ':' + ','.join('%x' % ord(ch) for ch in v) for k, v in items)
assert "'" not in table and '\\' not in table
line = "  const ENTITY_TABLE = '" + table + "';"
text = path.read_text(encoding='utf-8')
new, n = re.subn(r'(  // BEGIN ENTITIES\n).*?(\n  // END ENTITIES)', lambda m: m.group(1) + line + m.group(2), text, flags=re.S)
assert n == 1, 'markers not found'
path.write_text(new, encoding='utf-8')
print('wrote', len(items), 'entities')
