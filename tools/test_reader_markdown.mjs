// Tests Reader/src/markdown.js: the block parser, inline rendering and link rules.
//   node tools/test_reader_markdown.mjs
// Vectors (tools/reader-tests/):
//   parse-cases.json   blocks from a verbatim copy of Parley's MarkdownParser.parse
//   inline-cases.json  runs from a verbatim copy of MarkdownParser.inline + PendingLink
//   inline-oracle.json the same harness (tools/reader-tests/oracle.swift) on a wider corpus:
//                      emphasis, strikethrough, code spans, escapes, entities, links, autolinks, HTML
// The cases from Tests/ParleyAppTests/PresentationTests.swift and LinkConfirmationTests.swift are
// repeated below as they are written there.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const context = vm.createContext({ URL, TextEncoder, TextDecoder, atob, btoa, console });
vm.runInContext(readFileSync(join(root, 'Reader/src/markdown.js'), 'utf8'), context);
const M = context.ParleyMarkdown;
const same = value => JSON.parse(JSON.stringify(value)); // across vm realms
const vectors = name => JSON.parse(readFileSync(join(root, 'tools/reader-tests', name), 'utf8'));

let failures = 0, passed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message.split('\n').join('\n     ')}`); }
}

// Per UTF-16 unit: the styles and the link, so run boundaries do not matter.
function expand(runs) {
  const out = [];
  for (const r of runs) {
    const styles = [...r.styles].sort().join(',');
    const link = r.link ? JSON.stringify([r.link.url, r.link.host, r.link.address, r.link.hasHiddenCharacters]) : '';
    for (let i = 0; i < r.text.length; i++) out.push(styles + '|' + link);
  }
  return out;
}
const textOf = runs => runs.map(r => r.text).join('');
const linksOf = md => same(M.inline(md)).filter(r => r.link).map(r => r.link);

function checkInline(c) {
  const runs = same(M.inline(c.input));
  assert.equal(textOf(runs), c.text, 'visible text');
  const got = expand(runs), want = expand(c.runs);
  for (let i = 0; i < want.length; i++) {
    if (got[i] !== want[i]) assert.fail(`at ${i} (${JSON.stringify(c.text[i])}): got ${got[i]}, want ${want[i]}`);
  }
}

// Block parser ------------------------------------------------------------------------------------
for (const c of vectors('parse-cases.json')) {
  test(`parse ${JSON.stringify(c.input)}`, () => assert.deepEqual(same(M.parse(c.input)), c.blocks));
}

test('markdownListsBecomeListBlocks', () => {
  const blocks = same(M.parse('Intro\n\n- one\n- two\n  - nested\n1. first\n2) second\n- [x] done\n\nAfter'));
  assert.equal(blocks.length, 3);
  assert.deepEqual(blocks[0], { type: 'paragraph', text: 'Intro' });
  assert.deepEqual(blocks[2], { type: 'paragraph', text: 'After' });
  assert.equal(blocks[1].type, 'list');
  assert.deepEqual(blocks[1].items.map(i => i.text), ['one', 'two', 'nested', 'first', 'second', 'done']);
  assert.deepEqual(blocks[1].items.map(i => i.marker), ['•', '•', '◦', '1.', '2)', '☑']);
  assert.deepEqual(blocks[1].items.map(i => i.indent), [0, 0, 1, 0, 0, 0]);
});
test('markdownRuleAndCodeAreNotLists', () => {
  assert.deepEqual(same(M.parse('---\n```\n- not a list\n```')),
    [{ type: 'rule' }, { type: 'code', language: '', code: '- not a list' }]);
});
test('markdownInlineCodeIsStyled', () => {
  const code = same(M.inline('吃 `小笼包` 吧')).filter(r => r.styles.includes('code'));
  assert.equal(code.length, 1);
  assert.equal(code[0].text, '小笼包');
});

// Inline rendering --------------------------------------------------------------------------------
for (const c of vectors('inline-cases.json')) test(`inline ${JSON.stringify(c.input)}`, () => checkInline(c));
for (const c of vectors('inline-oracle.json')) test(`oracle ${JSON.stringify(c.input)}`, () => checkInline(c));

test('an image without alt text is a placeholder, never a link', () => {
  const runs = same(M.inline('x ![](https://i.example/p.png) y'));
  assert.equal(runs.filter(r => r.placeholder).length, 1);
  assert.equal(runs.filter(r => r.link).length, 0);
});
test('pathological nesting falls back to plain text instead of throwing', () => {
  const text = '*('.repeat(30000) + 'x' + ')*'.repeat(30000);
  assert.equal(textOf(same(M.inline(text))).length > 0, true);
  const many = '<!--'.repeat(20000) + '`'.repeat(3) + '*a'.repeat(20000);
  const started = Date.now();
  M.inline(many);
  assert.ok(Date.now() - started < 3000, 'linear enough');
});

// Hostile inputs stay linear (SEC-1). Each is rendered the way the page does it (parse, then
// inline on every block) and must finish within a budget; the result is checked too.
function renderAll(text) {
  const out = [];
  for (const b of M.parse(text)) {
    if (b.text !== undefined) out.push(...M.inline(b.text));
    if (b.items) for (const i of b.items) out.push(...M.inline(i.text));
  }
  return same(out);
}
function withinBudget(name, text, check, budget = 200) {
  test(`${name} (${Math.round(text.length / 1000)} K characters) renders in under ${budget} ms`, () => {
    const started = performance.now();
    const runs = renderAll(text);
    const took = performance.now() - started;
    assert.ok(took < budget, `took ${Math.round(took)} ms`);
    if (check) check(runs);
  });
}
withinBudget('"_www." repeated (checkDomain rescans)', '_www.'.repeat(20000), runs => {
  assert.equal(textOf(runs).length, 100000);
  assert.equal(runs.filter(r => r.link).length, 0);
});
withinBudget('"www.a_b." repeated (checkDomain, labels with underscores)', ' www.a_b.c'.repeat(10000), runs => {
  assert.equal(runs.filter(r => r.link).length, 0);
});
withinBudget('an autolink followed by 80 000 ")" (autolinkDelim recounts)', 'http://a.b/' + ')'.repeat(80000), runs => {
  const links = runs.filter(r => r.link);
  assert.equal(links.length, 1);
  assert.equal(links[0].text, 'http://a.b/');
});
withinBudget('a balanced autolink with many parentheses', 'see https://a.b/' + '(x)'.repeat(20000) + '))). ', runs => {
  assert.equal(runs.filter(r => r.link)[0].text, 'https://a.b/' + '(x)'.repeat(20000));
});
withinBudget('one line of "a", 40 000 spaces, "b" (trim backtracking)', 'a' + ' '.repeat(40000) + 'b', runs => {
  assert.equal(textOf(runs).length, 40002);
});
withinBudget('a line of 1 000 000 spaces between letters', 'a' + ' 　'.repeat(500000) + 'b', null, 400);
withinBudget('40 000 "![" then 40 000 "[](x)" (bracket deactivation walk)', '!['.repeat(40000) + '[](x)'.repeat(40000), runs => {
  assert.equal(textOf(runs), '!['.repeat(40000));
});
withinBudget('"`a" repeated 80 000 times (backtick run scan)', '`a'.repeat(80000), runs => {
  assert.equal(runs.filter(r => r.styles.includes('code')).length, 40000);
});
withinBudget('"`a``b" repeated (backtick runs of two lengths)', '`a``b'.repeat(40000));
test('blocks are trimmed of TAB and Zs only, as before', () => {
  assert.deepEqual(same(M.parse('\t　 # Title  \t')), [{ type: 'heading', level: 1, text: 'Title' }]);
  assert.deepEqual(same(M.parse(' x ')), [{ type: 'paragraph', text: ' x ' }]);
  assert.deepEqual(same(M.parse('``` swift \ncode\n ``` ')), [{ type: 'code', language: 'swift', code: 'code' }]);
});

// Link rules (LinkConfirmationTests.swift) ---------------------------------------------------------
const linksThatMayOpen = ['http://example.com/', 'https://example.com/a?b=1#c', 'HTTP://Example.COM/', 'https://[::1]:8443/x',
  'http://192.168.1.20:1234/v1', 'https://8.8.8.8/', 'https://[::ffff:8.8.8.8]/', 'https://a.b1/',
  'https://example.com/%2E%2E?q=%41', 'https://docs.example@notes.example/view'];
const linksThatNeverOpen = ['mailto:a@example.com?body=secret', 'file:///etc/passwd', 'javascript:alert(1)', 'ftp://example.com/',
  'ssh://example.com/', 'tel:+15551234', 'foo/bar', '//evil.example/x', 'https:evil.example', 'https:///evil.example',
  'https://accounts.good.example%2Eevil%2Enet/?q=secret', 'https://%65vil.example/', 'https://good.example%2F.evil.example/',
  'http://010.010.010.010/', 'http://0177.1.2.3/', 'http://0x7f.1/', 'http://134744072/', 'http://10.1/', 'http://1.2.3.0x/'];
test('linksThatMayOpen', () => {
  for (const u of linksThatMayOpen) {
    const link = M.pendingLink(u);
    assert.ok(link, u);
    assert.equal(link.url, u);
  }
});
test('linksThatNeverOpen', () => {
  for (const u of linksThatNeverOpen) assert.equal(M.pendingLink(u), null, u);
});
test('renderedTextHoldsNoRealLink', () => {
  for (const md of ['[docs](https://example.com/a)', '<https://example.com/a>', 'https://example.com/a',
    '[a][r]\n\n[r]: https://example.com/a', '[![i](https://img.example/x.png)](https://example.com/a)']) {
    const links = linksOf(md);
    assert.equal(links.length, 1, md);
    assert.equal(links[0].url, 'https://example.com/a', md);
  }
});
test('linksThatNeverOpenAreNotLinks', () => {
  for (const md of ['[a](mailto:a@example.com)', '[a](file:///etc/passwd)', '[a](javascript:alert(1))', '[a](foo/bar)',
    '[a](https:evil.example)', '[a](https://%65vil.example/)', '[a](http://010.010.010.010/)', '[a](https://e .example/)']) {
    const runs = same(M.inline(md));
    assert.equal(runs.filter(r => r.link).length, 0, md);
    assert.equal(textOf(runs), 'a', md);
  }
});
const inert = a => 'parley-link:' + Buffer.from(a, 'utf8').toString('base64');
test('aModelCannotForgeAnInertLink', () => {
  assert.equal(linksOf(`[a](${inert('https://evil.example/x')})`)[0].url, 'https://evil.example/x');
  assert.deepEqual(linksOf(`[a](${inert('file:///etc/passwd')})`), []);
  assert.deepEqual(linksOf(`[a](${inert(inert('https://evil.example/x'))})`), []);
  assert.deepEqual(linksOf('[a](parley-link:not%20base64)'), []);
});
test('theSheetShowsTheRealSite', () => {
  const link = M.pendingLink('https://docs.example@notes.example/view');
  assert.equal(link.host, 'notes.example');
  assert.equal(link.address, 'https://docs.example@notes.example/view');
  const apple = linksOf('[Apple](https://аррӏе.example/中文)')[0];
  assert.equal(apple.host, 'xn--80ak6aa92e.example');
  assert.equal(apple.address, 'https://xn--80ak6aa92e.example/%E4%B8%AD%E6%96%87');
  assert.equal(apple.hasHiddenCharacters, false);
});
test('addressesEscapeWhatCouldMisleadTheReader', () => {
  assert.equal(M.escapeAddress('https://example.com/a?b=~1'), 'https://example.com/a?b=~1');
  assert.equal(M.escapeAddress('a‮b'), 'a\\u{202E}b');
  assert.equal(M.escapeAddress('a​b'), 'a\\u{200B}b');
  assert.equal(M.escapeAddress('a\u{E0041}b'), 'a\\u{E0041}b');
  assert.equal(M.escapeAddress('aאb'), 'a\\u{5D0}b');
  assert.equal(M.escapeAddress('aاb'), 'a\\u{627}b');
  assert.equal(M.escapeAddress('aаb'), 'a\\u{430}b');
  assert.equal(M.escapeAddress('a b\nc\td'), 'a\\u{20}b\\u{A}c\\u{9}d');
});
test('LinkConfirmationFlow', () => {
  const opened = [];
  let asked = null;
  const gate = M.createLinkGate(u => opened.push(u), link => { asked = link; });
  const link = linksOf('[Official docs](https://notes.example/?q=secret)')[0];
  assert.equal(gate.requestOpen(link.url), true);
  assert.equal(asked.address, 'https://notes.example/?q=secret');
  assert.deepEqual(opened, []);
  gate.confirm();
  gate.confirm();
  assert.deepEqual(opened, ['https://notes.example/?q=secret']);
  assert.equal(gate.pending, null);

  gate.requestOpen(link.url);
  gate.cancel();
  gate.confirm();
  assert.equal(opened.length, 1);

  asked = null;
  assert.equal(gate.requestOpen('mailto:a@example.com'), false);
  assert.equal(gate.requestOpen('https:evil.example'), false);
  assert.equal(asked, null);
  assert.equal(gate.requestOpen('https://example.com/'), true);
  assert.equal(opened.length, 1, 'a raw URL still asks first');
});

// Tool display escaping (ToolDisplay.visible / line) -----------------------------------------------
test('hidden characters in tool text are shown', () => {
  assert.equal(M.visible('a​b‮c\u0007d\ne\tf'), 'a\\u{200B}b\\u{202E}c\\u{7}d\ne\tf');
  assert.equal(M.line('a\nb\tc '), 'a\\nb\\tc\\u{2028}');
});

console.log(failures ? `markdown: ${failures} failed, ${passed} passed` : `markdown: all ${passed} passed`);
process.exit(failures ? 1 : 0);
