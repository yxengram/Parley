#!/usr/bin/env python3
"""Localization helper for Parley (python3 3.9, standard library only).

    tools/l10n_check.py extract [--json] [--unclassified] [FILE...]
    tools/l10n_check.py check [--allow-missing]
    tools/l10n_check.py merge FRAGMENT.strings...

extract   Lists the localization keys the Swift sources use: SwiftUI literals (Text, Button, Label,
          .help, .accessibilityLabel, ...), parameters and properties typed LocalizedStringKey,
          String(localized:) and NSLocalizedString. Keys are the English text; an interpolation
          becomes a format specifier (%@, %lld, %lf, ...). Where the specifier depends on the
          interpolated value's type and the type is not obvious, the key is marked "type?": look
          at the declaration (Int -> %lld, Double -> %lf, String/Text/anything else -> %@).
          --unclassified also lists other literals that look like prose but are NOT localized
          (passed as String, concatenated, enum raw values, NSAlert text, ...): review them.
          With FILE arguments, only those files are scanned. Defaults: Sources/Parley (without
          Debug/) for SwiftUI keys, and Sources/ParleyCore for String(localized:) only.

check     Fails (exit 1) unless:
          - Resources/{en,zh-Hans}.lproj/{Localizable,InfoPlist}.strings parse (plutil -lint and
            this script's parser) and have no duplicate keys;
          - every en key has a non-empty zh-Hans value and the other way round;
          - each zh-Hans value carries exactly the key's format specifiers (positional %1$@ is fine);
          - every key the sources use (extract) is in the tables (compared with every specifier
            reduced to one placeholder, since extract cannot always know the type).
          --allow-missing reports missing keys but does not fail on them.

merge     Reads fragment files (.strings syntax: "English key" = "简体中文";), merges them into
          Resources/zh-Hans.lproj/Localizable.strings (a fragment wins over the existing value; two
          fragments that disagree are an error), and rewrites both Localizable.strings files
          sorted, en with key = key. Then runs check --allow-missing.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_SOURCES = os.path.join(ROOT, 'Sources', 'Parley')
CORE_SOURCES = os.path.join(ROOT, 'Sources', 'ParleyCore')
EXCLUDED_DIRS = {os.path.join(APP_SOURCES, 'Debug')}
RES = os.path.join(ROOT, 'Resources')
LANGS = ('en', 'zh-Hans')
TABLES = ('Localizable', 'InfoPlist')


def table_path(lang, table):
    return os.path.join(RES, lang + '.lproj', table + '.strings')


# ------------------------------------------------------------------------------------------------
# Swift lexing: string literals (with interpolations), comments, and a "skeleton" of the code in
# which every literal is replaced by a same-length run of spaces between quotes, so brackets and
# labels around a literal can be found by plain scanning.

SWIFT_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '"': '"', "'": "'", '\\': '\\'}


class Literal:
    def __init__(self, start, end, line, parts, raw, multiline):
        self.start, self.end, self.line = start, end, line
        self.parts = parts          # list of str (text) and ('expr', source) tuples
        self.raw = raw              # the literal as written
        self.multiline = multiline

    @property
    def interpolated(self):
        return any(isinstance(p, tuple) for p in self.parts)

    def text(self):
        return ''.join(p if isinstance(p, str) else '\\(' + p[1] + ')' for p in self.parts)


def lex_swift(src):
    """Returns (skeleton, literals). Only top-level literals are returned; literals inside an
    interpolation are part of their parent's expression text."""
    literals = []
    skel = list(src)
    i, n = 0, len(src)
    line = 1

    def blank(a, b):
        for k in range(a, b):
            if skel[k] != '\n':
                skel[k] = ' '

    def read_string(i):
        """i at the opening quote (or at the first '#' of a raw string). Returns (end, parts)."""
        hashes = 0
        while src[i] == '#':
            hashes += 1
            i += 1
        multiline = src.startswith('"""', i)
        q = '"""' if multiline else '"'
        i += len(q)
        closing = q + '#' * hashes
        esc = '\\' + '#' * hashes
        parts, buf = [], []
        while i < n:
            if src.startswith(closing, i):
                if buf:
                    parts.append(''.join(buf))
                return i + len(closing), parts, multiline
            if src.startswith(esc, i):
                j = i + len(esc)
                c = src[j] if j < n else ''
                if c == '(':
                    # interpolation: balanced parentheses, skipping nested strings
                    depth, k = 1, j + 1
                    while k < n and depth:
                        if src[k] == '"' or (src[k] == '#' and src[k:k + 2] in ('#"', '##')):
                            k2 = k
                            while src[k2] == '#':
                                k2 += 1
                            if src[k2] == '"':
                                k, _, _ = read_string(k)
                                continue
                        if src[k] == '(':
                            depth += 1
                        elif src[k] == ')':
                            depth -= 1
                        k += 1
                    if buf:
                        parts.append(''.join(buf))
                        buf = []
                    parts.append(('expr', src[j + 1:k - 1]))
                    i = k
                    continue
                if c == 'u' and j + 1 < n and src[j + 1] == '{':
                    k = src.index('}', j)
                    buf.append(chr(int(src[j + 2:k], 16)))
                    i = k + 1
                    continue
                if multiline and c == '\n':     # line continuation
                    i = j + 1
                    continue
                buf.append(SWIFT_ESCAPES.get(c, c))
                i = j + 1
                continue
            buf.append(src[i])
            i += 1
        raise ValueError('unterminated string literal')

    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
            continue
        if src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth += 1
                    j += 2
                elif src.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
            continue
        if c == '"' or (c == '#' and re.match(r'#+"', src[i:i + 8])):
            start = i
            end, parts, multiline = read_string(i)
            raw = src[start:end]
            lit = Literal(start, end, src.count('\n', 0, start) + 1, parts, raw, multiline)
            literals.append(lit)
            # Keep the quotes so the skeleton still shows a literal, blank the inside.
            q_open = raw.index('"')
            blank(start, end)
            skel[start + q_open] = '"'
            skel[end - 1 - raw[::-1].index('"')] = '"'
            i = end
            continue
        i += 1
    return ''.join(skel), literals


# ------------------------------------------------------------------------------------------------
# Context of a literal: the innermost call it is an argument of (callee and argument label), or,
# outside any call, the declaration whose body it is in.

OPENERS, CLOSERS = '([{', ')]}'


def enclosing_open(skel, pos):
    """Index of the innermost unmatched opener before pos, or -1."""
    depth = {'(': 0, '[': 0, '{': 0}
    match = {')': '(', ']': '[', '}': '{'}
    i = pos - 1
    stack = 0
    while i >= 0:
        c = skel[i]
        if c in CLOSERS:
            stack += 1
        elif c in OPENERS:
            if stack == 0:
                return i
            stack -= 1
        i -= 1
    return -1


def callee_before(skel, paren):
    m = re.search(r'([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*|\.[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^<>()]*>)?\s*$',
                  skel[max(0, paren - 200):paren])
    if not m:
        return None
    name = re.sub(r'\s+', '', m.group(1))
    return name


def argument_label(skel, paren, pos):
    """The label of the argument at pos in the call opened at paren (None if unlabeled), and its
    index among the call's arguments."""
    seg_start, depth, index = paren + 1, 0, 0
    for i in range(paren + 1, pos):
        c = skel[i]
        if c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            depth -= 1
        elif c == ',' and depth == 0:
            seg_start = i + 1
            index += 1
    seg = skel[seg_start:pos]
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)', seg)
    return (m.group(1) if m else None), index


def short_name(callee):
    return callee.split('.')[-1] if callee else None


# SwiftUI initializers whose first unlabeled argument is a LocalizedStringKey (or a title that
# is one when given a literal).
SWIFTUI_TITLE_TYPES = {
    'Text', 'Button', 'Label', 'Toggle', 'Section', 'Picker', 'Menu', 'LabeledContent',
    'TextField', 'SecureField', 'Link', 'GroupBox', 'DisclosureGroup', 'Stepper', 'ProgressView',
    'Window', 'WindowGroup', 'ContentUnavailableView', 'ControlGroup', 'Tab', 'NavigationLink',
    'CommandMenu', 'Slider', 'DatePicker', 'ColorPicker', 'Gauge', 'MenuBarExtra', 'TextEditor',
    'LocalizedStringKey', 'LocalizedStringResource', 'SettingsLink', 'ShareLink', 'PasteButton',
}
# Modifiers whose first unlabeled argument is a LocalizedStringKey.
SWIFTUI_TITLE_MODIFIERS = {
    'help', 'accessibilityLabel', 'accessibilityHint', 'accessibilityValue', 'navigationTitle',
    'alert', 'confirmationDialog', 'badge', 'accessibilityAction', 'navigationSubtitle',
    'fileImporter', 'fileExporter',
}
# (callee, label) pairs that are LocalizedStringKey/LocalizationValue.
LABELED_KEYS = {
    ('String', 'localized'), ('searchable', 'prompt'), ('Text', 'localized'),
    ('LocalizedStringResource', None), ('AttributedString', 'localized'),
}
NOT_KEYS_LABELS = {'verbatim', 'systemImage', 'image', 'comment', 'table', 'tableName', 'bundle',
                   'value', 'format', 'id', 'named', 'specifier'}


def custom_key_parameters(files):
    """(Type or function name, label or None) for parameters and stored properties typed
    LocalizedStringKey / LocalizedStringResource in the given files."""
    found = set()
    decl = re.compile(r'\b(struct|class|enum|extension|actor)\s+([A-Za-z_][A-Za-z0-9_]*)')
    for path in files:
        src = open(path, encoding='utf-8').read()
        skel, _ = lex_swift(src)
        lsk = r'(?:SwiftUI\.)?Localized(?:StringKey|StringResource)\??'
        # parameters: init( / func name( ... label name: LocalizedStringKey
        for m in re.finditer(r'\b(init|func\s+([A-Za-z_][A-Za-z0-9_]*))\s*(?:<[^>]*>)?\s*\(', skel):
            depth, j = 1, m.end()
            while j < len(skel) and depth:
                if skel[j] == '(':
                    depth += 1
                elif skel[j] == ')':
                    depth -= 1
                j += 1
            params = skel[m.end():j - 1]
            if 'Localized' not in params:
                continue
            owner = m.group(2)
            if owner is None:   # init: the enclosing type
                types = [t for t in decl.finditer(skel[:m.start()])]
                owner = types[-1].group(2) if types else None
            for p in split_top(params):
                pm = re.match(r'\s*(?:@\w+\s+)*([A-Za-z_][A-Za-z0-9_]*)\s+(?:([A-Za-z_][A-Za-z0-9_]*)\s*)?:\s*' + lsk + r'\b', p)
                pm2 = re.match(r'\s*(?:@\w+\s+)*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*' + lsk + r'\b', p)
                if pm and pm.group(2):
                    label = None if pm.group(1) == '_' else pm.group(1)
                elif pm2:
                    label = pm2.group(1)
                else:
                    continue
                if owner:
                    found.add((owner, label))
        # stored properties (memberwise initializers)
        for m in re.finditer(r'\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*' + lsk + r'\s*(?:=|\n|$|;)', skel):
            types = [t for t in decl.finditer(skel[:m.start()])]
            if types:
                found.add((types[-1].group(2), m.group(1)))
    return found


def split_top(s):
    out, depth, cur = [], 0, []
    for c in s:
        if c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            depth -= 1
        if c == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
        else:
            cur.append(c)
    out.append(''.join(cur))
    return out


def declaration_returns_key(skel, pos):
    """For a literal outside any call: walks out through enclosing braces to the first
    declaration and says whether it is typed LocalizedStringKey/LocalizedStringResource
    (computed property, function result, or `let x: LocalizedStringKey = ...`)."""
    # Same statement: `let x: LocalizedStringKey = cond ? "a" : "b"` or `return "..."` handled below.
    line_start = skel.rfind('\n', 0, pos) + 1
    stmt = skel[line_start:pos]
    if re.search(r':\s*Localized(?:StringKey|StringResource)\??\s*=', stmt):
        return True
    p = pos
    for _ in range(12):
        o = enclosing_open(skel, p)
        if o < 0:
            return False
        if skel[o] != '{':
            p = o
            continue
        header_start = max(skel.rfind('\n', 0, o), skel.rfind('}', 0, o), skel.rfind('{', 0, o)) + 1
        header = skel[header_start:o]
        if re.search(r'\b(var|func|subscript|init|let)\b', header):
            return bool(re.search(r'(?:->|:)\s*(?:some\s+)?Localized(?:StringKey|StringResource)\??\s*(?:where[^{]*)?$', header.strip())) \
                or bool(re.search(r'Localized(?:StringKey|StringResource)\??\s*$', header.strip()))
        p = o
    return False


def classify(skel, lit, custom):
    """'key' if the literal is a localization key, 'skip' if it is clearly not user text, or
    None (unclassified: may be user text passed as String)."""
    pos = lit.start
    o = enclosing_open(skel, pos)
    if o >= 0 and skel[o] == '(':
        callee = callee_before(skel, o)
        label, index = argument_label(skel, o, pos)
        name = short_name(callee)
        if label in NOT_KEYS_LABELS:
            return 'skip', callee, label
        if (name, label) in LABELED_KEYS or (callee, label) in LABELED_KEYS:
            return 'key', callee, label
        if name == 'NSLocalizedString' and label is None and index == 0:
            return 'key', callee, label
        if label is None and index == 0:
            if callee in SWIFTUI_TITLE_TYPES or (name in SWIFTUI_TITLE_TYPES and callee == 'SwiftUI.' + name):
                return 'key', callee, label
            if callee and callee.startswith('.') and name in SWIFTUI_TITLE_MODIFIERS:
                return 'key', callee, label
        if name and (name, label) in custom:
            return 'key', callee, label
        if callee in ('keyboardShortcut', '.keyboardShortcut', 'Image', 'NSImage', 'systemName'):
            return 'skip', callee, label
        return None, callee, label
    if o >= 0 and skel[o] == '[':
        return None, '[', None
    if declaration_returns_key(skel, pos):
        return 'key', '(LocalizedStringKey declaration)', None
    return None, None, None


# Specifier for an interpolated value. SwiftUI and String.LocalizationValue use %lld for Int,
# %llu for UInt, %lf for Double, %f for Float, %@ for String, Text, Image, AttributedString and
# objects; `specifier:` overrides.
INT_HINT = re.compile(r'(\.count|Count|count|Index|index|Number|number|Total|total|Tokens|tokens|'
                      r'^n$|^i$|Int\(|\.size$|Limit|limit|Seconds|seconds|Minutes|minutes|Hours|hours|'
                      r'Days|days|bytes|Bytes|Length|length|Width|width|Height|height|Depth|depth)$')


def specifier_for(expr):
    e = expr.strip()
    m = re.search(r',\s*specifier:\s*"([^"]*)"\s*$', e)
    if m:
        return m.group(1), True
    if re.match(r'^(Text|Image)\(', e) or re.search(r',\s*(format|formatter|style):', e):
        return '%@', True
    if re.search(r'^String\(|\.description$|\.rawValue$|\.name$|\.title$|Name$|Title$|Text$|text$|Label$|label$|URL$|Host$|host$|path$|Path$|message$|Message$', e):
        return '%@', False
    if re.match(r'^Int(64|32)?\(', e) or INT_HINT.search(e):
        return '%lld', False
    if re.match(r'^(Double|CGFloat)\(', e):
        return '%lf', False
    return '%@', False


def mixed_ternary(skel, lit):
    """True when the literal is a branch of `cond ? "a" : name` whose other branch is not a
    literal: the expression is then a String, and Text/Button show it without a lookup."""
    o = enclosing_open(skel, lit.start)
    if o < 0 or skel[o] != '(':
        return False
    # the argument around the literal
    depth, start, end = 0, o + 1, len(skel)
    for i in range(o + 1, len(skel)):
        c = skel[i]
        if c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            if depth == 0:
                end = i
                break
            depth -= 1
        elif c == ',' and depth == 0:
            if i < lit.start:
                start = i + 1
            else:
                end = i
                break
    arg = skel[start:end]
    m = re.match(r'\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*:(?!:))?(.*)$', arg, re.S)
    arg = m.group(1)
    if not re.search(r'\s\?\s', arg):
        return False
    # c1 ? A : c2 ? B : C  ->  pieces after each '?': "A : c2", "B : C"; values are A, B and C.
    pieces = re.split(r'\s\?\s', arg)[1:]
    values = []
    for i, piece in enumerate(pieces):
        parts = re.split(r'\s:\s', piece, maxsplit=1)
        values.append(parts[0])
        if i == len(pieces) - 1 and len(parts) > 1:
            values.append(parts[1])
    return any(not re.fullmatch(r'\s*"[^"]*"\s*', v) for v in values)


def literal_key(lit, interpolation_escapes):
    """(key, certain) for a key literal. In an interpolated key, a literal % is written %%."""
    out, certain = [], True
    for p in lit.parts:
        if isinstance(p, str):
            out.append(p.replace('%', '%%') if interpolation_escapes else p)
        else:
            spec, sure = specifier_for(p[1])
            certain = certain and sure
            out.append(spec)
    return ''.join(out), certain


PROSE = re.compile(r'[A-Za-z]{2,}')


def looks_like_prose(lit):
    t = ''.join(p for p in lit.parts if isinstance(p, str))
    if not PROSE.search(t):
        return False
    if re.fullmatch(r'[a-z][A-Za-z0-9_.\-]*', t):      # identifiers, keys, symbol names
        return False
    if re.match(r'^(https?|file|data|about|mailto):', t) or t.startswith(('/', '.', '#', '{', '[', '<')):
        return False
    if re.fullmatch(r'[A-Za-z0-9_.\-]+\.[a-z]{2,5}', t):    # file names
        return False
    if re.fullmatch(r'[A-Z][A-Z0-9_]+', t):                 # CONSTANTS, env names
        return False
    return bool(re.search(r'[A-Z]', t) or ' ' in t)


def swift_files(root):
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if os.path.join(d, x) not in EXCLUDED_DIRS)
        for f in sorted(files):
            if f.endswith('.swift'):
                out.append(os.path.join(d, f))
    return out


def extract(files=None):
    """Returns (keys, unclassified). keys: list of dicts {key, certain, file, line, callee}."""
    app_files = swift_files(APP_SOURCES)
    core_files = swift_files(CORE_SOURCES)
    custom = custom_key_parameters(app_files)
    if files:
        files = [os.path.abspath(f) for f in files]
        targets = [(f, not f.startswith(CORE_SOURCES + os.sep)) for f in files]
    else:
        targets = [(f, True) for f in app_files] + [(f, False) for f in core_files]
    keys, unclassified = [], []
    for path, swiftui in targets:
        src = open(path, encoding='utf-8').read()
        skel, literals = lex_swift(src)
        rel = os.path.relpath(path, ROOT)
        for lit in literals:
            kind, callee, label = classify(skel, lit, custom if swiftui else set())
            if not swiftui and kind == 'key' and not ((short_name(callee), label) in LABELED_KEYS
                                                      or short_name(callee) in ('NSLocalizedString', 'LocalizedStringResource')
                                                      or callee == '(LocalizedStringKey declaration)'):
                kind = None
            if kind == 'key':
                key, certain = literal_key(lit, lit.interpolated)
                after = skel[lit.end:lit.end + 40].lstrip()
                before = skel[max(0, lit.start - 40):lit.start].rstrip()
                concatenated = after.startswith('+') or before.endswith('+') or mixed_ternary(skel, lit)
                keys.append({'key': key, 'certain': certain, 'file': rel, 'line': lit.line,
                             'callee': callee, 'concatenated': concatenated})
            elif kind is None and looks_like_prose(lit):
                if callee and short_name(callee) in ('log', 'print', 'debugPrint', 'fatalError', 'precondition',
                                                     'assert', 'assertionFailure', 'preconditionFailure', 'debug',
                                                     'info', 'error', 'warning', 'notice', 'trace', 'fault'):
                    continue
                unclassified.append({'text': lit.text(), 'file': rel, 'line': lit.line, 'callee': callee,
                                     'label': label})
    return keys, unclassified


# ------------------------------------------------------------------------------------------------
# .strings files

def parse_strings(text, path='<strings>'):
    """Returns a list of (key, value, line). Raises ValueError on syntax errors."""
    out, i, n = [], 0, len(text)
    if text.startswith('\ufeff'):
        i = 1

    def skip_ws(i):
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith('//', i):
                j = text.find('\n', i)
                i = n if j < 0 else j
            elif text.startswith('/*', i):
                j = text.find('*/', i + 2)
                if j < 0:
                    raise ValueError(f'{path}: unterminated comment')
                i = j + 2
            else:
                break
        return i

    def read_quoted(i):
        assert text[i] == '"'
        i += 1
        buf = []
        while i < n:
            c = text[i]
            if c == '"':
                return ''.join(buf), i + 1
            if c == '\\':
                d = text[i + 1]
                if d == 'n':
                    buf.append('\n')
                elif d == 't':
                    buf.append('\t')
                elif d == 'r':
                    buf.append('\r')
                elif d in 'Uu':
                    buf.append(chr(int(text[i + 2:i + 6], 16)))
                    i += 4
                else:
                    buf.append(d)
                i += 2
                continue
            buf.append(c)
            i += 1
        raise ValueError(f'{path}: unterminated string')

    while True:
        i = skip_ws(i)
        if i >= n:
            break
        line = text.count('\n', 0, i) + 1
        if text[i] != '"':
            raise ValueError(f'{path}:{line}: expected a quoted key')
        key, i = read_quoted(i)
        i = skip_ws(i)
        if i >= n or text[i] != '=':
            raise ValueError(f'{path}:{line}: expected = after key {key!r}')
        i = skip_ws(i + 1)
        if i >= n or text[i] != '"':
            raise ValueError(f'{path}:{line}: expected a quoted value for {key!r}')
        value, i = read_quoted(i)
        i = skip_ws(i)
        if i >= n or text[i] != ';':
            raise ValueError(f'{path}:{line}: expected ; after the value for {key!r}')
        i += 1
        out.append((key, value, line))
    return out


def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'


def write_strings(path, entries, header):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ['/* ' + header + ' */', '']
    for k, v in entries:
        lines.append(f'{quote(k)} = {quote(v)};')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')


def load_table(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding='utf-8') as f:
        return parse_strings(f.read(), path)


SPEC = re.compile(r'%(?:(\d+)\$)?([-+ 0#\']*)(\d+|\*)?(?:\.(\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAF%])')


def specifiers(s):
    """List of (position or None, spec without position). %% is skipped."""
    out = []
    for m in SPEC.finditer(s):
        if m.group(6) == '%':
            continue
        spec = '%' + (m.group(2) or '') + (m.group(3) or '') + ('.' + m.group(4) if m.group(4) else '') \
            + (m.group(5) or '') + m.group(6)
        out.append((int(m.group(1)) if m.group(1) else None, spec))
    return out


def specifier_problem(key, value):
    ks = [s for _, s in specifiers(key)]
    vs = specifiers(value)
    if any(p is not None for p, _ in vs):
        if any(p is None for p, _ in vs):
            return 'mixes positional and plain specifiers'
        by_pos = {}
        for p, s in vs:
            by_pos.setdefault(p, set()).add(s)
        expected = {i + 1: {s} for i, s in enumerate(ks)}
        if by_pos != expected:
            return f'specifiers {sorted((p, sorted(s)) for p, s in by_pos.items())} do not match the key\'s {ks}'
        return None
    if [s for _, s in vs] != ks:
        return f'specifiers {[s for _, s in vs]} do not match the key\'s {ks}'
    return None


def normalize(key):
    """Every specifier reduced to one placeholder, for comparing extracted keys with table keys."""
    return SPEC.sub(lambda m: '%%' if m.group(6) == '%' else '\u0000', key)


def needs_translation(key):
    """Keys without letters outside specifiers (e.g. "%@ · %@", "—") need no translation."""
    return bool(re.search(r'[A-Za-z]', SPEC.sub('', key)))


def lint(path):
    r = subprocess.run(['/usr/bin/plutil', '-lint', path], capture_output=True, text=True)
    return None if r.returncode == 0 else (r.stdout + r.stderr).strip()


# ------------------------------------------------------------------------------------------------
# Commands

def cmd_extract(args):
    as_json = '--json' in args
    show_unclassified = '--unclassified' in args
    files = [a for a in args if not a.startswith('--')]
    keys, unclassified = extract(files or None)
    if as_json:
        json.dump({'keys': keys, 'unclassified': unclassified if show_unclassified else []},
                  sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    seen = {}
    for k in keys:
        seen.setdefault(k['key'], []).append(k)
    for key in sorted(seen):
        locs = seen[key]
        flags = []
        if not all(x['certain'] for x in locs):
            flags.append('type?')
        if any(x['concatenated'] for x in locs):
            flags.append('NOT LOOKED UP: concatenated or ternary with a String, so shown as written')
        where = ', '.join(f"{x['file']}:{x['line']}" for x in locs[:4]) + (' ...' if len(locs) > 4 else '')
        print(f'{quote(key)}    // {where}' + (f'  [{"; ".join(flags)}]' if flags else ''))
    print(f'// {len(seen)} keys', file=sys.stderr)
    if show_unclassified:
        print('\n// Unclassified literals (look like prose, not localized as written):')
        for u in unclassified:
            ctx = f"{u['callee'] or '-'}" + (f" {u['label']}:" if u['label'] else '')
            print(f"//   {u['file']}:{u['line']}  [{ctx}]  {quote(u['text'])}")
    return 0


def cmd_check(args):
    allow_missing = '--allow-missing' in args
    errors, warnings = [], []
    tables = {}
    for table in TABLES:
        for lang in LANGS:
            path = table_path(lang, table)
            rel = os.path.relpath(path, ROOT)
            if not os.path.exists(path):
                errors.append(f'{rel} is missing')
                continue
            problem = lint(path)
            if problem:
                errors.append(f'plutil -lint {rel}: {problem}')
            try:
                entries = load_table(path)
            except (ValueError, IndexError) as e:
                errors.append(str(e))
                continue
            d = {}
            for k, v, line in entries:
                if k in d:
                    errors.append(f'{rel}:{line}: duplicate key {quote(k)}')
                d[k] = v
            tables[(lang, table)] = d
    for table in TABLES:
        en, zh = tables.get(('en', table)), tables.get(('zh-Hans', table))
        if en is None or zh is None:
            continue
        for k in sorted(set(en) - set(zh)):
            errors.append(f'{table}: zh-Hans has no value for {quote(k)}')
        for k in sorted(set(zh) - set(en)):
            errors.append(f'{table}: en has no entry for {quote(k)} (run merge to regenerate en)')
        for k, v in sorted(zh.items()):
            if not v.strip():
                errors.append(f'{table}: empty zh-Hans value for {quote(k)}')
                continue
            problem = specifier_problem(k, v)
            if problem:
                errors.append(f'{table}: {quote(k)} = {quote(v)}: {problem}')
        if table == 'Localizable':
            for k, v in sorted(en.items()):
                if v != k:
                    warnings.append(f'en value differs from its key: {quote(k)} = {quote(v)}')
    zh = tables.get(('zh-Hans', 'Localizable')) or {}
    known = {}
    for k in zh:
        known.setdefault(normalize(k), []).append(k)
    keys, _ = extract()
    missing = {}
    for k in keys:
        if not needs_translation(k['key']):
            continue
        candidates = known.get(normalize(k['key']))
        if not candidates:
            missing.setdefault(k['key'], []).append(f"{k['file']}:{k['line']}")
        elif k['certain'] and k['key'] not in candidates:
            # The specifiers are known from the source (no interpolation, Text/Image, specifier:):
            # a table key with other specifiers is never looked up.
            errors.append(f"{k['file']}:{k['line']}: the source looks up {quote(k['key'])}, "
                          f"but the table has {', '.join(quote(c) for c in candidates)}")
        if k['concatenated']:
            warnings.append(f"{k['file']}:{k['line']}: {quote(k['key'])} is concatenated with + or in a ternary with a String, so it is a String and not looked up")
    used = {normalize(k['key']) for k in keys}
    for k in sorted(zh):
        if normalize(k) not in used:
            warnings.append(f'not found by extract (computed with String(localized:) from a variable, or stale?): {quote(k)}')
    for k in sorted(missing):
        msg = f'missing translation: {quote(k)}  ({", ".join(missing[k][:3])})'
        (warnings if allow_missing else errors).append(msg)
    for w in warnings:
        print('warning: ' + w)
    for e in errors:
        print('error: ' + e)
    total = len({normalize(k['key']) for k in keys if needs_translation(k['key'])})
    print(f'l10n_check: {len(zh)} zh-Hans entries, {total} keys in the sources, {len(missing)} missing, '
          f'{len(errors)} errors, {len(warnings)} warnings')
    return 1 if errors else 0


def cmd_merge(args):
    if not args:
        print('usage: l10n_check.py merge FRAGMENT.strings...', file=sys.stderr)
        return 64
    zh_path, en_path = table_path('zh-Hans', 'Localizable'), table_path('en', 'Localizable')
    existing = {}
    for k, v, _ in (load_table(zh_path) or []):
        existing[k] = v
    merged_from = {}
    errors = []
    for frag in args:
        with open(frag, encoding='utf-8') as f:
            try:
                entries = parse_strings(f.read(), frag)
            except (ValueError, IndexError) as e:
                errors.append(str(e))
                continue
        for k, v, line in entries:
            if k in merged_from and merged_from[k][1] != v:
                errors.append(f'{frag}:{line}: {quote(k)} = {quote(v)} conflicts with {merged_from[k][0]}: {quote(merged_from[k][1])}')
                continue
            problem = specifier_problem(k, v)
            if problem:
                errors.append(f'{frag}:{line}: {quote(k)}: {problem}')
            merged_from[k] = (frag, v)
    if errors:
        for e in errors:
            print('error: ' + e)
        print('merge: nothing written')
        return 1
    for k, (_, v) in merged_from.items():
        existing[k] = v
    items = sorted(existing.items(), key=lambda kv: (kv[0].lower(), kv[0]))
    header = 'Generated by tools/l10n_check.py merge. Keys are the English text; keep the file sorted.'
    write_strings(zh_path, items, header)
    write_strings(en_path, [(k, k) for k, _ in items], header)
    print(f'merge: {len(merged_from)} entries from {len(args)} fragments; {len(items)} entries written to '
          f'{os.path.relpath(zh_path, ROOT)} and {os.path.relpath(en_path, ROOT)}')
    return cmd_check(['--allow-missing'])


def main(argv):
    if len(argv) < 2 or argv[1] not in ('extract', 'check', 'merge'):
        print(__doc__.strip(), file=sys.stderr)
        return 64
    return {'extract': cmd_extract, 'check': cmd_check, 'merge': cmd_merge}[argv[1]](argv[2:])


if __name__ == '__main__':
    sys.exit(main(sys.argv))
