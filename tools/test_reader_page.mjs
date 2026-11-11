// Static audit of the built reader page: the hard rules as a test.
//   node tools/test_reader_page.mjs BUILT_HTML
// Checks the CSP, that every script is inline and parses, that no API that reaches the network or
// writes markup from strings appears, that there are no real links, external URLs or inline event
// handlers, and that the art is embedded. Also checks the two string tables (English, Simplified
// Chinese) and the language pick.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const path = process.argv[2];
if (!path) { console.error('usage: node tools/test_reader_page.mjs BUILT_HTML'); process.exit(64); }
const html = readFileSync(path, 'utf8');

let failures = 0, passed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message}`); }
}

const CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; base-uri 'none'; form-action 'none'";
const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/gi)];
const code = scripts.map(m => m[2]).join('\n');
// The page outside its scripts (markup, CSS), with the embedded pictures cut out.
const markup = html.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '<script></script>');

test('the Content-Security-Policy meta tag is the first thing after the charset', () => {
  const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]*)">/.exec(html);
  assert.ok(meta, 'CSP meta present');
  assert.equal(meta[1], CSP);
  assert.ok(html.indexOf(meta[0]) < html.indexOf('<script'), 'CSP before any script');
  assert.ok(html.indexOf(meta[0]) < html.indexOf('<style'), 'CSP before any style');
});
test('four inline scripts, none with src, all parse', () => {
  assert.equal(scripts.length, 4);
  for (const [, attrs, body] of scripts) {
    assert.equal(attrs.trim(), '', 'no script attributes');
    new vm.Script(body); // throws on a syntax error
  }
});
test('placeholders are filled and the art is embedded', () => {
  assert.ok(!html.includes('/*@@'), 'no placeholder left');
  const art = /window\.PARLEY_ART = (\{.*?\});/.exec(html);
  assert.ok(art);
  const pictures = JSON.parse(art[1]);
  const names = ['door-day', 'door-night', 'fort-day', 'fort-night'].flatMap(n => [n, n + '-pillow', n + '-treehouse']).sort();
  assert.deepEqual(Object.keys(pictures).sort(), names);
  for (const v of Object.values(pictures)) assert.match(v, /^data:image\/jpeg;base64,\/9j\//);
});
test('no network or markup-from-string APIs in any script', () => {
  const banned = ['fetch(', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', 'importScripts', 'innerHTML', 'outerHTML',
    'insertAdjacentHTML', 'document.write', 'srcdoc', 'DOMParser', 'createContextualFragment', 'eval(', 'new Function', 'setAttribute(\'href',
    'setAttribute("href', '.href', 'location', 'javascript:', 'Worker(', 'navigator.serviceWorker', 'indexedDB', 'sessionStorage', 'document.cookie'];
  for (const word of banned) assert.ok(!code.includes(word), `script uses ${word}`);
});
test('window.open appears once, with noopener and noreferrer', () => {
  const opens = code.match(/window\.open\(/g) || [];
  assert.equal(opens.length, 1);
  assert.ok(code.includes("window.open(url, '_blank', 'noopener,noreferrer')"));
});
test('localStorage holds only the look (skin and light)', () => {
  const uses = [...code.matchAll(/localStorage\.(\w+)\(([^,)]*)/g)].map(m => m[1] + ' ' + m[2]);
  assert.deepEqual([...new Set(uses)].sort(), ['getItem LOOK_KEY', 'setItem LOOK_KEY']);
  assert.ok(code.includes("const LOOK_KEY = 'parley-reader.look';"));
  assert.ok(code.includes('localStorage.setItem(LOOK_KEY, JSON.stringify(look))'));
});
test('no real links, external URLs or inline event handlers', () => {
  assert.ok(!/\shref\s*=/i.test(markup), 'href attribute in markup');
  assert.ok(!/<(a|link|iframe|object|embed|form|base|meta http-equiv="refresh")\b/i.test(markup.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '')), 'element that loads or navigates');
  assert.ok(!/<[^>]+\son[a-z]+\s*=/i.test(markup), 'inline event handler');
  assert.ok(!/url\(\s*['"]?(https?:|\/\/)/i.test(markup), 'CSS url() to the network');
  assert.ok(!/@import/i.test(markup), 'CSS @import');
  const urls = (html.replace(/data:image\/jpeg;base64,[A-Za-z0-9+/=]+/g, '').match(/https?:\/\/[A-Za-z0-9[][^\s'"`)<]*/g) || []);
  assert.deepEqual([...new Set(urls)], ['http://www.w3.org/2000/svg'], 'only the SVG namespace');
});
test('file text reaches the DOM through textContent only', () => {
  // The page's own h() helper is the one place attributes are set from data; it must not set href/src/style/on*.
  assert.ok(/else if \(key === 'text'\) el\.textContent = v;/.test(code));
  const srcs = code.match(/\.src = [^;]+;/g) || [];
  for (const s of srcs) assert.ok(['.src = url;'].includes(s), `unexpected src assignment ${s}`);
});

test('the page opts out of browser translation, which would send its text to a service (SEC-5)', () => {
  assert.match(html, /<html lang="en" translate="no">/);
  const csp = html.indexOf('<meta http-equiv="Content-Security-Policy"');
  const google = html.indexOf('<meta name="google" content="notranslate">');
  assert.ok(google > csp, 'notranslate meta present, after the CSP meta');
  assert.ok(google < html.indexOf('<style') && google < html.indexOf('<script'), 'in the head, before styles and scripts');
});

// The page's own script, and pure pieces of it run in node. A piece is cut out between two
// anchors that must each appear exactly once, so a rename fails here instead of testing nothing.
const page = scripts[scripts.length - 1][2];
function piece(start, end) {
  const a = page.indexOf(start), b = page.indexOf(end, a + 1);
  assert.ok(a >= 0 && page.indexOf(start, a + 1) < 0, `anchor ${start} once`);
  assert.ok(b > a, `anchor ${end} after ${start}`);
  return page.slice(a, b);
}
// The string tables, pickLanguage and t(), run with a fixed language instead of the browser's.
const i18n = () => piece('  const STRINGS = {', '  function browserLanguages() {');
function run(source, names, lang = 'en') {
  const context = vm.createContext({});
  vm.runInContext(i18n() + `\nconst LANG = ${JSON.stringify(lang)}, LOCALE = ${JSON.stringify(lang)};\n`
    + piece('  const str = v =>', '  const dateOf') + '\nconst grouped = n => String(n);\n'
    + source + `\nthis.out = { ${names.join(', ')} };`, context);
  return context.out;
}
const { STRINGS, pickLanguage } = run('', ['STRINGS', 'pickLanguage']);
const placeholders = text => [...text.matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort();
const same = value => JSON.parse(JSON.stringify(value));
const timed = fn => { const t = performance.now(); const v = fn(); return [v, performance.now() - t]; };

test('tool-call arguments keep a "__proto__" key in the Arguments board and its copy (SEC-2)', () => {
  const { prettyArguments } = run(piece('  function sortKeysDeep(', '  function replayResult('), ['prettyArguments']);
  const out = prettyArguments('{"path":"/tmp/x","__proto__":{"command":"rm -rf ~","a":[{"__proto__":1}]}}');
  assert.ok(out.includes('"__proto__" : {'), out);
  assert.ok(out.includes('"command" : "rm -rf ~"'), out);
  assert.ok(out.includes('"__proto__" : 1'), out);
  assert.ok(out.indexOf('"__proto__"') < out.indexOf('"path"'), 'keys stay sorted');
  assert.equal(prettyArguments('{"b":1,"a":{"d":2,"c":3}}'), '{\n  "a" : {\n    "c" : 3,\n    "d" : 2\n  },\n  "b" : 1\n}');
  assert.equal(prettyArguments(' {} '), '{}');
  assert.equal(prettyArguments('not json'), 'not json');
  assert.equal(({}).polluted, undefined);
});

test('a tool status such as "constructor" falls back to Finished instead of breaking the message (SEC-4)', () => {
  const { statusOf } = run(piece('  const STATUS = {', '  function toolTitle('), ['statusOf']);
  for (const status of ['constructor', 'toString', 'hasOwnProperty', '__proto__', 'valueOf', 42, null]) {
    const got = same(statusOf({ result: { status } }));
    assert.deepEqual(got, ['question', 'Finished', 'var(--inkSoft)'], String(status));
  }
  assert.deepEqual(same(statusOf({ result: { status: 'completed' } })), ['check', 'Done', 'var(--moss)']);
  assert.deepEqual(same(statusOf({ result: { status: 'cancelled' }, startedAt: null })), ['stop', 'Stopped', 'var(--inkSoft)']);
  assert.deepEqual(same(statusOf({})), ['stop', 'Interrupted', 'var(--inkSoft)']);
  // Conversation details: the effort lookup is own-keys only too.
  assert.ok(page.includes("Object.prototype.hasOwnProperty.call(EFFORT, str(st.reasoningEffort))"));
  assert.ok(!/\{ low: 'Low', medium: 'Medium', high: 'High' \}\[/.test(page));
});

const errors = () => run(piece('  function serverMessage(', '  function errorCallout('),
  ['presentError', 'displayText', 'htmlSummary']);

test('an HTML error page shows its title, never its markup, in Details and the tooltip (F2)', () => {
  const { presentError, displayText } = errors();
  const raw = 'HTTP 502: <!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body><h1>Bad</h1></body></html>';
  const p = presentError(raw, {});
  assert.equal(p.title, '502 Bad Gateway');
  assert.equal(p.status, 'HTTP 502');
  assert.equal(p.raw, 'HTTP 502: 502 Bad Gateway');
  assert.equal(displayText(raw), 'HTTP 502: 502 Bad Gateway');
  // The app's fallbacks: the first heading, then "HTML page".
  assert.equal(presentError('HTTP 500: <html><body><h1>Down &amp; out</h1></body></html>', {}).title, 'Down & out');
  assert.equal(presentError('HTTP 500 <html><body><p>x</p></body></html>', {}).raw, 'HTTP 500: HTML page');
  assert.equal(presentError('HTTP 404: <title>Not\n  <b>here</b></title>', {}).detail, 'Check the model ID and the base URL. The server said: Not here');
  // Leftmost match, like NSRegularExpression: the first <title> that has a </title> after it.
  assert.equal(presentError('HTTP 500: <title>a<title>b</title>', {}).title, 'a b');
  // Not HTML: the stored text stays as it is.
  assert.equal(displayText('  HTTP 500: {"error":"<title>x</title>"} '), '  HTTP 500: {"error":"<title>x</title>"} ');
  assert.equal(presentError('HTTP 500: {"error":{"message":"boom"}}', {}).title, 'boom');
  assert.equal(displayText('The request timed out.'), 'The request timed out.');
});

test('connection and timeout errors have no Details toggle (F3)', () => {
  const { presentError } = errors();
  const timeout = presentError('The request timed out.', {});
  assert.equal(timeout.title, 'The server took too long to respond');
  assert.equal(timeout.detail, 'The request timed out.');
  assert.equal(timeout.raw, null);
  const refused = presentError('Could not connect to the server.', {});
  assert.equal(refused.title, 'Can\'t reach the server');
  assert.equal(refused.raw, null);
  assert.equal(presentError('Something else', {}).raw, 'Something else');
});

test('hostile HTML error bodies stay linear (SEC-1)', () => {
  const { presentError } = errors();
  const cases = [
    ['HTTP 500 <html>' + '<title>'.repeat(40000), 'HTML page'],
    ['HTTP 500 <html>' + '<h1>x'.repeat(40000) + '\r</h1>', 'HTML page'],
    ['HTTP 500 <html>' + '<h1'.repeat(80000) + '>x\r</h1>', 'HTML page'],
    ['HTTP 500 <html><title>' + '<'.repeat(200000) + '</title>', '<'.repeat(200)],
    ['HTTP 500 <html><title>' + '  '.repeat(200000) + 'x</title>', 'x'],
    ['HTTP 500 <html><title>' + '&amp;'.repeat(100000) + '</title>', '&'.repeat(200)],
  ];
  for (const [raw, summary] of cases) {
    const [p, took] = timed(() => presentError(raw, {}));
    assert.equal(p.raw, 'HTTP 500: ' + summary, raw.slice(0, 40));
    assert.ok(took < 200, `${raw.slice(0, 30)}… took ${Math.round(took)} ms`);
  }
});

test('a tool note with a huge padded detail stays linear (SEC-1, toolNoteText)', () => {
  const { toolNoteText } = run(piece('  /** Trims \'.\' and whitespace', '  // ---- error presentation'), ['toolNoteText']);
  assert.equal(toolNoteText({ kind: 'serverUnavailable', detail: ' .Files. \n' }), 'Files. Its tools were not offered.');
  assert.equal(toolNoteText({ kind: 'serverUnavailable' }), 'A server. Its tools were not offered.');
  const detail = 'a' + ' '.repeat(100000) + 'b' + ' .'.repeat(100000);
  const [text, took] = timed(() => toolNoteText({ kind: 'serverUnavailable', detail }));
  assert.equal(text, 'a' + ' '.repeat(100000) + 'b. Its tools were not offered.');
  assert.ok(took < 200, `took ${Math.round(took)} ms`);
});

test('file errors use the app\'s ParleyError wording (F9)', () => {
  const { errorText } = run(piece('  const ERROR_TEXT = {', '  function readText(') + piece('  /** ParleyError.errorDescription', '  async function openFiles('), ['errorText']);
  const err = (code, detail) => ({ name: 'ReaderError', code, detail });
  assert.equal(errorText(err('unsupportedVersion', '2')), 'Unsupported conversation file version 2.');
  assert.equal(errorText(err('corrupt', 'invalid JSON')), 'The conversation file is damaged: invalid JSON');
  assert.equal(errorText(err('corrupt', 'something from the file')), 'The conversation file is damaged.');
  assert.equal(errorText(err('notParley')), 'This file is not a Parley conversation.');
  assert.equal(errorText(err('constructor')), 'The file couldn\'t be read.');
  assert.equal(errorText(new Error('x')), 'The file couldn\'t be read.');
});

test('strings and elements match the app (F9, F10)', () => {
  const en = STRINGS.en;
  assert.ok(!markup.includes('reader-label'), 'no READER label next to the wordmark');
  assert.ok(markup.includes('<div class="wordmark lettered">Parley</div>'));
  assert.equal(en.privacyNote, 'Files you open stay in this browser tab. Nothing is uploaded.');
  assert.ok(page.includes("h('span', { text: t('privacyNote') })"));
  assert.ok(!page.includes('Parley Reader shows conversations'), 'no second paragraph on the empty screen');
  assert.equal(en.lanternOn, 'The lantern\'s on');
  assert.ok(page.includes("text: t('lanternOn')"));
  assert.equal(en.forgottenPasswords, 'Forgotten passwords can\'t be recovered.');
  assert.ok(page.includes("text: t('forgottenPasswords')"));
  assert.ok(!/’/.test(page), 'straight apostrophes, as in the app');
  assert.ok(!page.includes("'Decrypting…'") && !Object.values(STRINGS).some(table => /…$/.test(table.decrypting)), 'the unlock spinner has no visible words');
  assert.ok(page.includes("h('span', { class: 'sr-only', text: t('decrypting') })"));
  assert.equal(en.encryptedSub, 'Encrypted · {name}');
  assert.ok(page.includes("const sub = entry.encrypted ? t('encryptedSub', { name: entry.name }) : '';"), 'no subtitle for a plain file');
  assert.ok(!page.includes("title: t('showsArgs')") && !page.includes('slip.title'), 'tool slips have no tooltip');
});

test('layout rules match the app (F1, F4, F5, F6, F7, F8, F11) and the page prints in full (PRINT)', () => {
  assert.ok(markup.includes('background: linear-gradient(to bottom, var(--wall), var(--wall-bottom)), var(--paper);'), 'F1 wall over paper');
  assert.ok(!/\.row:(hover|focus-within) \.row-lock[^{]*\{[^}]*visibility:\s*hidden/.test(markup), 'F4 the padlock is never hidden');
  assert.ok(/\.row\.selected\.locked \.row-title \{ font-weight: 500; color: var\(--inkSoft\); \}/.test(markup), 'F5');
  assert.ok(markup.indexOf('.row.selected.locked .row-title') > markup.indexOf('.row.selected .row-title'), 'F5 rule comes later');
  assert.ok(/\.row \{[^}]*margin: 2px 23px 2px 24px;/.test(markup) && /\.group-title \{[^}]*padding: 10px 14px 2px;/.test(markup), 'F6 insets');
  assert.ok(/\.search \{ margin: 8px 12px 8px;/.test(markup) && /\.wordmark \{[^}]*margin: 8px 0 0;/.test(markup), 'F6 spacing');
  assert.ok(markup.includes('.scroller.no-messages > .column {') && page.includes("' no-messages'"), 'F7');
  assert.ok(/\.empty-detail \{[^}]*padding: 40px;/.test(markup) && markup.includes('.empty-detail .taped { margin-bottom: 12px; }')
    && page.includes("h('div', { class: 'empty-detail' }"), 'F8');
  assert.ok(!/max-width: 760px/.test(html), 'F11 no 760 breakpoint');
  assert.ok(markup.includes('@media (max-width: 640px)') && page.includes("window.matchMedia('(max-width: 640px)')"), 'F11');
  const print = /@media print \{([\s\S]*?)\n\}/.exec(markup);
  assert.ok(print, 'an @media print block');
  for (const rule of ['html, body { height: auto; overflow: visible; }', '.wall, .scrim, .to-bottom, .toasts, .actions',
    '.room, .room-body, .scroller { display: block; overflow: visible; height: auto; min-height: 0; flex: none; }', 'content-visibility: visible']) {
    assert.ok(print[1].includes(rule), `print: ${rule}`);
  }
});

test('toasts stay on screen; many failures become one toast (TOAST-OVERFLOW)', () => {
  assert.ok(/\.toasts \{[^}]*max-height: calc\(100vh - 32px\); overflow-y: auto;/.test(markup));
  assert.ok(page.includes('if (failed.length > 3) {'));
});

test('text from the file lays out in its own direction; code stays LTR (RTL-NO-DIR-AUTO)', () => {
  for (const cls of ["class: 'note', dir: 'auto'", "inlineInto(h('p', { class: 'md-p' }), b.text, 'auto')",
    "inlineInto(h('div', { class: `md-h md-h${lvl}`, role: 'heading', 'aria-level': Math.min(b.level + 2, 6) }), b.text, 'auto')",
    "class: 'md-li', dir: 'auto'", "inlineInto(h('blockquote', { class: 'md-quote' }), b.text, 'auto')", "class: 'thinking-body', dir: 'auto'",
    "class: 'board-text', dir: 'auto'", "class: 'row-title', dir:", "class: 'header-title', dir:", "class: 'code-body', dir: 'ltr'"]) {
    assert.ok(page.includes(cls), cls);
  }
});

test('markdown blocks are filled before dir=auto is set, and huge blocks fall back to plain text (N1)', () => {
  const fill = piece('  function inlineInto(el, text, dir) {', '  /** Above this, a text is shown as plain text');
  assert.ok(fill.includes('const frag = document.createDocumentFragment();') && fill.includes('el.append(frag);'));
  assert.ok(fill.indexOf('el.append(frag);') < fill.indexOf('if (dir) el.dir = dir;'));
  assert.ok(fill.includes('if (runs.length > MAX_INLINE_RUNS) {') && page.includes('const MAX_INLINE_RUNS = 5000;'));
});

test('lock and remove leave nothing from the conversation in dialogs (SEC-3)', () => {
  const clear = piece('  function clearDialog(d) {', '  function closeDialogs(');
  assert.ok(clear.includes("d.replaceChildren();") && clear.includes("if (d === imageDialog) d.setAttribute('aria-label', t('imagePreview'));"));
  assert.ok(page.includes('function closeDialogs() { gate.cancel(); for (const d of allDialogs) { if (d.open) d.close(); clearDialog(d); } }'));
  assert.ok(page.includes("on(d, 'close', () => { clearDialog(d);"));
});

test('decrypt state lives on the entry; focus moves on after unlock and remove (UNLOCK-SWITCH-AWAY, FOCUS-AFTER-UNLOCK)', () => {
  const unlock = piece('  function unlockScreen(entry) {', '  function spinner() {');
  assert.ok(unlock.includes('if (working()) status.append('), 'a new screen shows the running attempt');
  assert.ok(unlock.includes('else if (entry.unlockError)'), 'and the last failure');
  assert.ok(/entry\.unlockError = [^;]+;\s*entry\.unlockShake = true;[^]*?if \(selectedKey === entry\.key\) \{ renderRoom\(\); announce\(entry\.unlockError\); \}/.test(unlock));
  assert.ok(!/\bstatus\.replaceChildren\(/.test(unlock), 'no writes to a screen that may be gone');
  assert.ok(unlock.includes('entry.view.scroller.focus({ preventScroll: true })'));
  assert.ok(page.includes('function removeAndRefocus(entry, main)') && (page.match(/removeAndRefocus\(entry, main\)/g) || []).length === 4);
});

test('a bad image cannot take its message down (B64-BACKTRACK)', () => {
  const image = piece('  function imageURL(entry, a) {', '  function imageThumb(');
  assert.ok(/try \{[\s\S]*Core\.base64ToBytes[\s\S]*\} catch \(_\) \{\s*return null;/.test(image));
  assert.ok(page.includes('if (text.length > MARKDOWN_LIMIT)'), 'SEC-1 backstop: huge texts render as plain text');
});

// ---- languages (English and Simplified Chinese)
test('both string tables have the same keys, the same {placeholders} and no empty text (L10N)', () => {
  const en = Object.keys(STRINGS.en).sort(), zh = Object.keys(STRINGS['zh-Hans']).sort();
  assert.deepEqual(Object.keys(STRINGS).sort(), ['en', 'zh-Hans']);
  assert.deepEqual(zh, en, 'same keys');
  for (const key of en) {
    for (const lang of ['en', 'zh-Hans']) {
      assert.equal(typeof STRINGS[lang][key], 'string', `${lang}.${key}`);
      assert.ok(STRINGS[lang][key].length > 0, `${lang}.${key} is empty`);
    }
    assert.deepEqual(placeholders(STRINGS['zh-Hans'][key]), placeholders(STRINGS.en[key]), `placeholders of ${key}`);
  }
  // Every key is translated, except text that is the same in both languages.
  const same = en.filter(key => STRINGS.en[key] === STRINGS['zh-Hans'][key]);
  assert.deepEqual(same, ['pageTitle', 'quoted', 'tokensPerSecond'], 'untranslated keys');
  for (const key of en) assert.ok(!/’/.test(STRINGS['zh-Hans'][key]), `${key}: no curly apostrophe`);
});

test('every key the page asks for exists, and every key is used (L10N)', () => {
  const asked = new Set([...page.matchAll(/\bt\('(\w+)'/g)].map(m => m[1]));
  for (const m of page.matchAll(/t\(partial \? '(\w+)' : '(\w+)'/g)) { asked.add(m[1]); asked.add(m[2]); }
  for (const m of markup.matchAll(/data-i18n(?:-[a-z-]+)?="(\w+)"/g)) asked.add(m[1]);
  for (const m of page.matchAll(/: '(group\w+)'/g)) asked.add(m[1]);
  for (const key of asked) assert.ok(Object.prototype.hasOwnProperty.call(STRINGS.en, key), `unknown key ${key}`);
  const unused = Object.keys(STRINGS.en).filter(key => !asked.has(key));
  assert.deepEqual(unused, [], 'keys no code uses');
});

test('the markup is translated at startup; the static lang stays for browsers without script (L10N)', () => {
  for (const attr of ['data-i18n-title', 'data-i18n-aria-label', 'data-i18n-placeholder']) assert.ok(markup.includes(attr), attr);
  assert.ok(markup.includes('<div class="drop-card lettered" id="drop-card" data-i18n="dropFiles">'));
  assert.ok(page.includes('document.documentElement.lang = LANG;') && page.includes("document.title = t('pageTitle');"));
  // The static pass runs before any shape or icon is added to the elements it fills.
  const pass = page.indexOf("querySelectorAll('[data-i18n]')");
  assert.ok(pass > 0 && pass < page.indexOf('addShape(document.getElementById(') && pass < page.indexOf('function addShape('));
  assert.ok(/:root:lang\(zh\) \{ --lettered: var\(--rounded\); \}/.test(markup), 'no Noteworthy for Chinese');
  for (const call of ['new Intl.DateTimeFormat(LOCALE, opts)', 'toLocaleString(LOCALE)', 'new Intl.RelativeTimeFormat(LOCALE,']) assert.ok(page.includes(call), call);
});

test('the language follows the first browser language: Chinese, else English (L10N)', () => {
  const pick = list => pickLanguage(list).lang;
  for (const list of [['zh-CN'], ['zh'], ['zh-SG'], ['zh-Hans-HK'], ['zh_CN'], ['zh-TW', 'zh-CN'], ['zh-TW'], ['zh-HK'], ['zh-MO'],
    ['zh-Hant'], ['zh-Hant-CN'], ['zh-TW', 'en-US'], ['  zh-CN ', 'en']]) {
    assert.equal(pick(list), 'zh-Hans', JSON.stringify(list));
  }
  // Japanese or French first is English, even with Chinese later in the list (the app does the same).
  for (const list of [['ja', 'fr'], ['ja', 'zh-Hans'], ['fr', 'zh-Hans-CN', 'en'], ['en-GB', 'zh-CN'], [], [42, null], 'zh-CN']) {
    assert.equal(pick(list), 'en', JSON.stringify(list));
  }
  assert.deepEqual(same(pickLanguage(['en-GB', 'zh-CN'])), { lang: 'en', locale: 'en-GB' });
  assert.deepEqual(same(pickLanguage(['zh-Hans-CN', 'ja'])), { lang: 'zh-Hans', locale: 'zh-Hans-CN' });
  assert.deepEqual(same(pickLanguage(['zh-TW'])), { lang: 'zh-Hans', locale: 'zh-Hans' }, 'one script on the page');
  assert.deepEqual(same(pickLanguage(['ja', 'zh-Hans-CN'])), { lang: 'en', locale: 'en' });
  assert.deepEqual(same(pickLanguage(['ja', 'fr'])), { lang: 'en', locale: 'en' }, 'English dates with the English fallback');
});

test('t() fills each placeholder once, never from file text, and falls back to English (L10N)', () => {
  const { t } = run('', ['t'], 'zh-Hans');
  assert.equal(t('cantOpenOne', { name: '{name}$&$\'.json' }), '无法打开“{name}$&$\'.json”');
  assert.equal(t('noMatch', { query: '__proto__' }), '没有与“__proto__”匹配的对话。');
  assert.equal(t('cantOpenOne', {}), '无法打开“{name}”', 'a missing value leaves the placeholder');
  assert.equal(t('no such key'), 'no such key');
  assert.equal(t('constructor'), 'constructor', 'own keys only');
  assert.equal(run('', ['t'], 'fr').t('copy'), 'Copy', 'an unknown language gives English');
});

test('file errors in Chinese match the app\'s ParleyError translations (L10N, F9)', () => {
  const { errorText } = run(piece('  const ERROR_TEXT = {', '  function readText(') + piece('  /** ParleyError.errorDescription', '  async function openFiles('), ['errorText'], 'zh-Hans');
  const err = (code, detail) => ({ name: 'ReaderError', code, detail });
  assert.equal(errorText(err('unsupportedVersion', '2')), '不支持的对话文件版本 2。');
  assert.equal(errorText(err('unsupportedVersion', 'x')), '不支持的对话文件版本。');
  assert.equal(errorText(err('corrupt', 'invalid JSON')), '对话文件已损坏：invalid JSON', 'damage details stay English codes');
  assert.equal(errorText(err('corrupt', 'something from the file')), '对话文件已损坏。');
  assert.equal(errorText(err('notParley')), '此文件不是 Parley 对话。');
  assert.equal(errorText(err('constructor')), '无法读取此文件。');
  assert.equal(STRINGS['zh-Hans'].errWrongPassword, '密码错误，或文件已被篡改。');
  assert.equal(STRINGS.en.errWrongPassword, 'Wrong password, or the file has been tampered with.');
});

test('in Chinese, stored English errors are still recognised; only the words around them change (L10N)', () => {
  const { presentError, toolNoteText, statusOf } = run(piece('  function serverMessage(', '  function errorCallout(')
    + piece('  /** Trims \'.\' and whitespace', '  // ---- error presentation') + piece('  const STATUS = {', '  function toolTitle('),
  ['presentError', 'toolNoteText', 'statusOf'], 'zh-Hans');
  const timeout = presentError('The request timed out.', {});
  assert.equal(timeout.title, '服务器响应超时');
  assert.equal(timeout.detail, 'The request timed out.');
  assert.equal(presentError('Could not connect to the server.', {}).detail, '服务器是否正在运行？Could not connect to the server.');
  assert.equal(presentError('HTTP 401: {}', {}).title, '服务器拒绝了 API 密钥');
  assert.equal(presentError('HTTP 500 <html><body><p>x</p></body></html>', {}).raw, 'HTTP 500: HTML 页面');
  const dropped = presentError('API error: The connection closed before the reply finished (through Cloudflare).', { content: 'x' });
  assert.equal(dropped.detail, '已收到的文本会保留。经由 Cloudflare 的连接在回复中途关闭：服务器或网络已断开。重试会重新请求完整的回复。');
  assert.equal(presentError('context length exceeded', { toolDefinitionTokens: 1200 }).detail, '工具定义大约占用其中 1200 个 token。请用扳手按钮（⇧⌘T）关闭不需要的服务器或工具。');
  assert.equal(toolNoteText({ kind: 'serverUnavailable', detail: 'Files.' }), 'Files。它的工具未提供给模型。');
  assert.deepEqual(same(statusOf({ result: { status: 'completed' } })), ['check', '完成', 'var(--moss)']);
  const replay = piece('  function replayResult(', '  function boardBlock(');
  assert.ok(replay.includes("'(The tool returned no output.)'") && !replay.includes("t('"), 'the texts the model was sent stay English');
});

console.log(failures ? `page: ${failures} failed, ${passed} passed` : `page: all ${passed} passed`);
process.exit(failures ? 1 : 0);
