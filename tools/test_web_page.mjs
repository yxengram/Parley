// Static audit of the built Parley Web page: the hard rules as a test.
//   node tools/test_web_page.mjs BUILT_HTML        (tools/build_web.sh OUT first)
// The Reader's audit, with the one difference Parley Web has: it talks to the servers the user adds,
// so the CSP says connect-src *, and network APIs may appear in exactly one script, chat.js
// (ParleyChat); the page's own script never calls fetch or anything like it. Checks the CSP, that
// every script is inline and parses, that no API that writes markup from strings appears, that there
// are no real links (except the one download link made in saveTextFile), external URLs or inline
// event handlers, and that the art is embedded. Also checks the two string tables (English,
// Simplified Chinese), the language pick, and pure pieces of the page's script run in node.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const path = process.argv[2];
if (!path) { console.error('usage: node tools/test_web_page.mjs BUILT_HTML'); process.exit(64); }
const html = readFileSync(path, 'utf8');

let failures = 0, passed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message}`); }
}

const CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src http: https:; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'";
const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/gi)];
// The page outside its scripts (markup, CSS), with the embedded pictures cut out.
const markup = html.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '<script></script>');
// Script order: art, core, markdown, chat, context, store, page.
const [ART_JS, CORE_JS, MARKDOWN_JS, CHAT_JS, CONTEXT_JS, STORE_JS, PAGE_JS] = scripts.map(m => m[2]);
const code = scripts.map(m => m[2]).join('\n');
// Everything but ParleyChat: none of it may reach the network.
const codeWithoutChat = scripts.filter((_, i) => i !== 3).map(m => m[2]).join('\n');

// The page's own script, and pure pieces of it run in node. A piece is cut out between two
// anchors that must each appear exactly once, so a rename fails here instead of testing nothing.
const page = PAGE_JS;
function piece(start, end) {
  const a = page.indexOf(start), b = page.indexOf(end, a + 1);
  assert.ok(a >= 0 && page.indexOf(start, a + 1) < 0, `anchor ${start} once`);
  assert.ok(b > a, `anchor ${end} after ${start}`);
  return page.slice(a, b);
}
test('the Content-Security-Policy meta tag is the first thing after the charset', () => {
  const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]*)">/.exec(html);
  assert.ok(meta, 'CSP meta present');
  assert.equal(meta[1], CSP);
  assert.ok(html.indexOf(meta[0]) < html.indexOf('<script'), 'CSP before any script');
  assert.ok(html.indexOf(meta[0]) < html.indexOf('<style'), 'CSP before any style');
});
test('seven inline scripts (art, core, markdown, chat, context, store, page), none with src, all parse', () => {
  assert.equal(scripts.length, 7);
  assert.ok(/^\s*const ParleyChat = /m.test(CHAT_JS) && /^\s*const ParleyContext = /m.test(CONTEXT_JS) && /^\s*const ParleyStore = /m.test(STORE_JS), 'the modules are in their slots');
  assert.ok(PAGE_JS.includes("const Core = window.ParleyCore;"), 'the page script is last');
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
test('network APIs appear only inside the chat.js script block (ParleyChat), never in the page or the other modules', () => {
  const network = ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', 'importScripts', 'Worker(', 'navigator.serviceWorker', 'RTCPeerConnection'];
  for (const word of network) assert.ok(!codeWithoutChat.includes(word), `outside chat.js: ${word}`);
  // chat.js is the one place: the global fetch is reached through doFetch, once.
  assert.ok(CHAT_JS.includes('globalThis.fetch'), 'ParleyChat uses fetch');
  assert.equal((CHAT_JS.match(/globalThis\.fetch/g) || []).length, 1, 'one place reaches fetch');
  for (const word of ['XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', 'importScripts']) assert.ok(!CHAT_JS.includes(word), `chat.js: ${word}`);
  // Gaps the plain substrings above would miss: dynamic access, imports, image/audio loaders, Request objects, injected fetch.
  for (const word of ['import(', 'new Image', 'new Audio', 'Request(', 'Reflect.get(globalThis', 'globalThis[', 'window[', 'fetchImpl']) assert.ok(!codeWithoutChat.includes(word), `outside chat.js: ${word}`);
  assert.ok(!/\bh\(\s*['"][a-z0-9]+['"]\s*,\s*\{[^}]*\b(href|src|srcset|poster|ping|action|formaction)\s*:/.test(PAGE_JS), 'h() attributes never carry URLs');
  assert.ok(!/createElement\(['"](script|iframe|link|form|embed|object|img|audio|video|base)/.test(PAGE_JS), 'no network-loading element made from script');
  assert.equal((CHAT_JS.match(/doFetch\(/g) || []).length, 3, 'doFetch: the definition and its two calls');
  // The page calls ParleyChat for every request.
  assert.ok(PAGE_JS.includes('Chat.streamChat(') && PAGE_JS.includes('Chat.listModels('));
});
test('no markup-from-string, eval or storage-escape APIs in any script', () => {
  const banned = ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'srcdoc', 'DOMParser', 'createContextualFragment', 'eval(', 'new Function',
    'setAttribute(\'href', 'setAttribute("href', 'javascript:', 'sessionStorage', 'document.cookie'];
  for (const word of banned) assert.ok(!code.includes(word), `script uses ${word}`);
  // location is read by chat.js for a redirect's header only; the page never touches it.
  assert.ok(!codeWithoutChat.includes('location'), 'location outside chat.js');
  assert.ok(!/(?<![\w.])location\b/.test(PAGE_JS) && !PAGE_JS.includes('window.location'), 'the page script does not navigate');
  assert.ok(![ART_JS, CORE_JS, MARKDOWN_JS, CONTEXT_JS, STORE_JS].some(js => js.includes('.href')), '.href in a module (the page\'s one download link is checked below)');
});
test('nothing is logged to the console: no message text, no keys (privacy)', () => {
  assert.ok(!/\bconsole\./.test(code), 'console used');
});
test('IndexedDB is reached only through ParleyStore; the page hands it the factory once', () => {
  assert.ok(STORE_JS.includes('indexedDB'));
  for (const [name, js] of [['core', CORE_JS], ['markdown', MARKDOWN_JS], ['chat', CHAT_JS], ['context', CONTEXT_JS]]) assert.ok(!js.includes('indexedDB'), name);
  assert.equal((PAGE_JS.match(/indexedDB/g) || []).length, 1);
  assert.ok(PAGE_JS.includes('factory = window.indexedDB;') && PAGE_JS.includes('Store.probe(factory)'));
});
test('the one download: a File System Access save dialog, else a temporary link made in saveTextFile and nowhere else', () => {
  const fn = piece('  async function saveTextFile(', '  const fileNameFor');
  assert.ok(fn.includes('window.showSaveFilePicker'), 'the save dialog is preferred');
  assert.equal((PAGE_JS.match(/document\.createElement\('a'\)/g) || []).length, 1, 'one link element in the page');
  assert.equal((fn.match(/document\.createElement\('a'\)/g) || []).length, 1, '...made in saveTextFile');
  assert.equal((PAGE_JS.match(/\.href\b/g) || []).length, 1, 'one .href in the page');
  assert.ok(fn.includes('link.href = url;') && fn.includes("link.download = filename;") && fn.includes('link.click();'));
  assert.ok(fn.includes('URL.createObjectURL(new Blob([text]') && fn.includes('URL.revokeObjectURL(url)'), 'a blob: URL of text the page made, revoked afterwards');
  assert.ok(!fn.includes("h('a'"), 'never through the h() helper');
});
test('an encrypted export is never named after the plaintext title (security)', () => {
  const fn = piece('  async function exportEntry(', '  // ---- import');
  assert.ok(fn.includes("base = entry.encrypted ? t('encryptedRow') : nameOf(conversation);"));
});
test('server errors are scrubbed of the API key and capped before they are stored', () => {
  assert.ok(PAGE_JS.includes('const scrubError = '));
  assert.ok(/m\.error = scrubError\(/.test(PAGE_JS));
  assert.ok((PAGE_JS.match(/scrubError\(/g) || []).length >= 3, 'run failure and both compaction paths');
});
test('delete stops saves before the row is removed; an unlocked encrypted entry survives a reload from another tab', () => {
  const del = piece('  function askDelete(', '  async function removeEntryLocally');
  assert.ok(del.indexOf('entry.discarded = true') < del.indexOf('store.remove') && del.includes('await entry.saving'));
  const load = piece('  async function loadEntry(', '  /** Forgets what is loaded');
  assert.ok(load.includes('Core.decryptWithKey(got.header, entry.keyInfo)'));
  const reload = piece('  function reloadEntry(', '  /** Brings the index row');
  assert.ok(reload.includes('dropView(entry, true)'), 'a reload keeps open dialogs');
});
test('window.open appears once, with noopener and noreferrer', () => {
  const opens = code.match(/window\.open\(/g) || [];
  assert.equal(opens.length, 1);
  assert.ok(code.includes("window.open(url, '_blank', 'noopener,noreferrer')"));
});
test('localStorage holds only the look (skin and light), under the page\'s own key', () => {
  const uses = [...code.matchAll(/localStorage\.(\w+)\(([^,)]*)/g)].map(m => m[1] + ' ' + m[2]);
  assert.deepEqual([...new Set(uses)].sort(), ['getItem LOOK_KEY', 'setItem LOOK_KEY']);
  assert.ok(code.includes("const LOOK_KEY = 'parley-web.look';"));
  assert.ok(code.includes('localStorage.setItem(LOOK_KEY, JSON.stringify(look))'));
});
test('no real links, external URLs or inline event handlers', () => {
  assert.ok(!/\shref\s*=/i.test(markup), 'href attribute in markup');
  assert.ok(!/<(a|link|iframe|object|embed|form|base|meta http-equiv="refresh")\b/i.test(markup.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '')), 'element that loads or navigates');
  assert.ok(!/<a\b/i.test(markup), 'no link element in the markup');
  assert.ok(!/<[^>]+\son[a-z]+\s*=/i.test(markup), 'inline event handler');
  assert.ok(!/url\(\s*['"]?(https?:|\/\/)/i.test(markup), 'CSS url() to the network');
  assert.ok(!/@import/i.test(markup), 'CSS @import');
  const stripped = html.replace(/data:image\/jpeg;base64,[A-Za-z0-9+/=]+/g, '');
  assert.ok(!/wss?:\/\/|["'`]\/\/[a-z]/i.test(stripped), 'ws, wss or protocol-relative URL');
  const urls = (stripped.match(/https?:\/\/[A-Za-z0-9[][^\s'"`)<]*/g) || []);
  // Example addresses of servers (a placeholder, an error hint) are text, not requests: local or placeholder hosts only.
  const example = /^https?:\/\/(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|host)(:\d+)?(\/|$)/;
  assert.deepEqual([...new Set(urls.filter(u => !example.test(u)))], ['http://www.w3.org/2000/svg'], 'only the SVG namespace');
});
test('file text reaches the DOM through textContent only', () => {
  // The page's own h() helper is the one place attributes are set from data; it must not set href/src/style/on*.
  assert.ok(/else if \(key === 'text'\) el\.textContent = v;/.test(code));
  assert.ok(!/(?<![\w])(?:style|class)\s*:\s*(?:str|obj)\(/.test(PAGE_JS), 'no style or class taken straight from a conversation');
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
  // The kind and source labels are looked up in objects of literal t() calls, and the effort in a select: no table lookups by file text.
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
  const { errorText } = run(piece('  const ERROR_TEXT = {', '  function readText(') + piece('  /** ParleyError.errorDescription', '  // ---- state'), ['errorText']);
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
  assert.equal(en.pageTitle, 'Parley Web');
  assert.ok(html.includes('<title>Parley Web</title>'));
  assert.ok(page.includes("h('span', { text: t('privacyNote') })"));
  assert.equal(en.lanternOn, 'The lantern\'s on');
  assert.ok(page.includes("text: t('lanternOn')"));
  assert.equal(en.forgottenPasswords, 'Forgotten passwords can\'t be recovered.');
  assert.ok(page.includes("text: t('forgottenPasswords')"));
  assert.ok(!/’/.test(page), 'straight apostrophes, as in the app');
  assert.ok(!page.includes("'Decrypting…'") && !Object.values(STRINGS).some(table => /…$/.test(table.decrypting)), 'the unlock spinner has no visible words');
  assert.ok(page.includes("h('span', { class: 'sr-only', text: t('decrypting') })"));
  assert.ok(!page.includes("title: t('showsArgs')") && !page.includes('slip.title'), 'tool slips have no tooltip');
  // The Reader is a viewer; Parley Web is not.
  for (const text of ['Parley Reader', 'read-only', 'Nothing is uploaded']) assert.ok(!(markup + page).includes(text), `no "${text}" left from the Reader`);
});

test('layout rules match the app (F1, F4, F5, F6, F7, F8, F11) and the page prints in full (PRINT)', () => {
  assert.ok(markup.includes('background: linear-gradient(to bottom, var(--wall), var(--wall-bottom)), var(--paper);'), 'F1 wall over paper');
  assert.ok(!/\.row:(hover|focus-within) \.row-lock[^{]*\{[^}]*visibility:\s*hidden/.test(markup), 'F4 the padlock is never hidden');
  assert.ok(/\.row\.selected\.locked \.row-title \{ font-weight: 500; color: var\(--inkSoft\); \}/.test(markup), 'F5');
  assert.ok(markup.indexOf('.row.selected.locked .row-title') > markup.indexOf('.row.selected .row-title'), 'F5 rule comes later');
  assert.ok(/\.row \{[^}]*margin: 2px 23px 2px 24px;/.test(markup) && /\.group-title \{[^}]*padding: 10px 14px 2px;/.test(markup), 'F6 insets');
  assert.ok(/\.search \{ margin: 8px 12px 8px;/.test(markup) && /\.wordmark \{[^}]*margin: 8px 0 0;/.test(markup), 'F6 spacing');
  assert.ok(markup.includes('.scroller.no-messages > .column {') && page.includes("classList.toggle('no-messages'"), 'F7');
  assert.ok(/\.empty-detail \{[^}]*padding: 40px;/.test(markup) && markup.includes('.empty-detail .taped { margin-bottom: 12px; }')
    && page.includes("h('div', { class: 'empty-detail' }"), 'F8');
  assert.ok(!/max-width: 760px/.test(html), 'F11 no 760 breakpoint');
  assert.ok(markup.includes('@media (max-width: 640px)') && page.includes("window.matchMedia('(max-width: 640px)')"), 'F11');
  const print = /@media print \{([\s\S]*?)\n\}/.exec(markup);
  assert.ok(print, 'an @media print block');
  for (const rule of ['html, body { height: auto; overflow: visible; display: block; }', '.wall, .scrim, .to-bottom, .toasts, .actions',
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
  assert.ok(unlock.includes('entry.view.composer.input.focus({ preventScroll: true })'));
  // One key derivation opens the file and is kept to save it again; it is dropped with the conversation on Lock.
  assert.ok(unlock.includes('keyInfo = await Core.keyFromHeader(entry.header, password);') && unlock.includes('conversation = await Core.decryptWithKey(entry.header, keyInfo);'));
  assert.ok(!unlock.includes('Core.decrypt('), 'no second derivation');
  const lock = piece('  async function lockEntry(entry) {', '  /** Drops everything decrypted');
  assert.ok(lock.indexOf('entry.runDone') < lock.indexOf('await saveNow(entry)') && lock.indexOf('await saveNow(entry)') < lock.indexOf('entry.keyInfo = null'), 'stop, save, then drop the key');
  assert.ok(lock.includes('entry.conversation = null;') && lock.includes('dropView(entry);'));
});

test('a bad image cannot take its message down (B64-BACKTRACK)', () => {
  const image = piece('  function imageURL(entry, a, sink) {', '  function imageThumb(');
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
  assert.deepEqual(same.sort(), ['kindLMStudio', 'kindLlamaCpp', 'kindOllama', 'kindStrata', 'kindVLLM', 'pageTitle', 'quoted', 'thresholdRange', 'tokensPerSecond'], 'untranslated keys');
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
  assert.ok(markup.includes('data-i18n-aria-label="conversationSettings"') && markup.includes('id="settings-dialog"'));
  assert.ok(page.includes('document.documentElement.lang = LANG;') && page.includes("document.title = t('pageTitle');"));
  // The static pass runs before any shape or icon is added to the elements it fills.
  const pass = page.indexOf("querySelectorAll('[data-i18n]')");
  assert.ok(pass > 0 && pass < page.indexOf('addShape(document.getElementById(') && pass < page.indexOf('function addShape('));
  assert.ok(/:root:lang\(zh\) \{ --lettered: var\(--rounded\); \}/.test(markup), 'no Noteworthy for Chinese');
  for (const call of ['new Intl.DateTimeFormat(LOCALE, opts)', 'toLocaleString(LOCALE)', 'new Intl.RelativeTimeFormat(LOCALE,']) assert.ok(page.includes(call), call);
});

test('the language is the first browser language the page has, as macOS chooses for the app (L10N)', () => {
  const pick = list => pickLanguage(list).lang;
  // The same cases as macOSPicksTheFirstPreferredLanguageTheAppHas in Tests/ParleyAppTests/LocalizationTests.swift.
  for (const list of [['zh-Hans'], ['zh-CN'], ['zh'], ['zh-SG'], ['zh-Hans-HK'], ['zh_CN'], ['ja', 'zh-Hans'], ['fr', 'zh-Hans-CN', 'en'],
    ['zh-TW', 'zh-CN'], ['zh-HK', 'ja', 'zh-Hans'], ['  zh-CN ', 'en'], ['zh-Hant', 'zh-Hans']]) {
    assert.equal(pick(list), 'zh-Hans', JSON.stringify(list));
  }
  // Traditional Chinese is skipped like any language the page does not have.
  for (const list of [['zh-Hant'], ['zh-TW'], ['zh-HK'], ['zh-MO'], ['zh-Hant-CN'], ['zh-TW', 'en'], ['ja'], ['ja', 'fr'],
    ['en-GB', 'zh-CN'], ['de', 'en'], [], [42, null], 'zh-CN']) {
    assert.equal(pick(list), 'en', JSON.stringify(list));
  }
  assert.deepEqual(same(pickLanguage(['en-GB', 'zh-CN'])), { lang: 'en', locale: 'en-GB' });
  assert.deepEqual(same(pickLanguage(['zh-Hans-CN', 'ja'])), { lang: 'zh-Hans', locale: 'zh-Hans-CN' });
  assert.deepEqual(same(pickLanguage(['ja', 'zh-CN'])), { lang: 'zh-Hans', locale: 'zh-CN' }, 'dates from the matched tag');
  assert.deepEqual(same(pickLanguage(['zh-TW', 'fr', 'en-US'])), { lang: 'en', locale: 'en-US' });
  assert.deepEqual(same(pickLanguage(['zh-TW'])), { lang: 'en', locale: 'en' }, 'English dates with the English fallback');
  assert.deepEqual(same(pickLanguage(['ja', 'fr'])), { lang: 'en', locale: 'en' });
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
  const { errorText } = run(piece('  const ERROR_TEXT = {', '  function readText(') + piece('  /** ParleyError.errorDescription', '  // ---- state'), ['errorText'], 'zh-Hans');
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

// ---- multi-tab and file fixes, run against small stand-ins for the page's state
const later = [];
const atest = (name, fn) => later.push([name, fn]);
const STUBS = `
  let entries = [], selectedKey = null, store, convDialogEntry = null, activeElement = null;
  const toasts = [], selected = [], dropped = [], rendered = [];
  const toast = (title, message) => toasts.push(title);
  const middle = s => s;
  const ERROR_TEXT = {}, errorText = e => String(e.message);
  const readText = async f => f.text;
  const DEFAULT_TITLE = 'New Chat';
  const Ctx = { newID: (() => { let n = 0; return () => 'GEN' + (++n); })(), isoNow: () => '2026-01-01T00:00:00Z' };
  const entryOf = key => entries.find(e => e.key === key) || null;
  const select = key => selected.push(key);
  async function refreshList() { entries = (await store.list()).map(row => entries.find(e => e.id === row.id) || { key: row.id, id: row.id, row }); }
  const showStorageError = e => toasts.push('storageError');
  const convDialog = { open: true, closed: 0, close() { this.open = false; this.closed++; } };
  const dropView = (entry, keepDialogs) => dropped.push([entry.id, keepDialogs === true]);
  const renderRoom = () => rendered.push(1);
  const providerFor = () => null;
  const clearTimeout = () => {};
  globalThis.crypto = { subtle: {} };
  const document = { get activeElement() { return activeElement; } };
  const setup = o => { if ('store' in o) store = o.store; if ('entries' in o) entries = o.entries; if ('selectedKey' in o) selectedKey = o.selectedKey; if ('dialogEntry' in o) convDialogEntry = o.dialogEntry; if ('active' in o) activeElement = o.active; };
`;
const load = (source, names) => run(STUBS + source, ['setup', 'toasts', 'selected', 'dropped', 'rendered', 'convDialog', ...names]);
function memStore() {
  const rows = new Map();
  return {
    rows,
    async put(c) { rows.set(c.id.toUpperCase(), c); return c.id.toUpperCase(); },
    async putFile(text) { const id = JSON.parse(text).id; rows.set(id, { encrypted: true }); return id; },
    async list() { return [...rows.entries()].map(([id, c]) => ({ id, title: c.title, messageCount: (c.messages || []).length, encrypted: !!c.encrypted })); },
    importFile(text) {
      const o = JSON.parse(text);
      return o.encrypted ? { kind: 'encrypted', header: { id: o.id } } : { kind: 'plain', conversation: o };
    },
  };
}
const plainFile = (id, title) => ({ name: title + '.json', text: JSON.stringify({ id, title, messages: [] }) });
const lockedFile = id => ({ name: id + '.json', text: JSON.stringify({ id, encrypted: true }) });

atest('importing several files stores every one; same-id files in a batch become copies (IMPORT-MANY)', async () => {
  const m = load(piece('  async function importFiles(', '  // ---- new, rename'), ['importFiles']);
  const st = memStore();
  m.setup({ store: st, entries: [], selectedKey: null });
  await m.importFiles([plainFile('AAAA', 'A'), plainFile('BBBB', 'B'), plainFile('CCCC', 'C')]);
  assert.deepEqual([...st.rows.keys()].sort(), ['AAAA', 'BBBB', 'CCCC']);
  assert.deepEqual(same(m.selected), ['AAAA'], 'the first one is shown');
  const st2 = memStore();
  m.setup({ store: st2, entries: [] });
  await m.importFiles([plainFile('DDDD', 'one'), plainFile('dddd', 'two')]);
  assert.equal(st2.rows.size, 2, 'the second is stored as a copy, not overwritten');
  assert.deepEqual([...st2.rows.values()].map(c => c.title).sort(), ['one', 'two']);
  const st3 = memStore();
  m.setup({ store: st3, entries: [] });
  m.toasts.length = 0;
  await m.importFiles([lockedFile('E1'), lockedFile('E2'), lockedFile('E1')]);
  assert.deepEqual([...st3.rows.keys()].sort(), ['E1', 'E2']);
  assert.equal(m.toasts.length, 1, 'the repeated encrypted file says it is already here');
});
atest('export of a row that was never opened reads the stored conversation (EXPORT-UNLOADED)', async () => {
  const m = load(`const saved = []; const saveTextFile = async (n, text) => { saved.push([n, text]); };
    const fileNameFor = x => x + '.json'; const nameOf = c => c.title;` + piece('  async function exportEntry(', '  // ---- import'), ['exportEntry', 'saved']);
  const conv = { id: 'A', title: 'Stored title', messages: [] };
  m.setup({ store: { get: async () => ({ kind: 'plain', conversation: conv }), exportFile: async c => JSON.stringify({ conversation: c }) } });
  await m.exportEntry({ id: 'A', encrypted: false, conversation: null });
  assert.deepEqual(same(m.saved), [['Stored title.json', JSON.stringify({ conversation: conv })]]);
  m.saved.length = 0;
  m.setup({ store: { get: async () => ({ kind: 'encrypted', text: 'CIPHER' }), exportFile: async () => { throw new Error('no'); } } });
  await m.exportEntry({ id: 'A', encrypted: true, conversation: null });
  assert.equal(m.saved.length, 1);
  assert.equal(m.saved[0][1], 'CIPHER');
  assert.ok(!m.saved[0][0].includes('Stored'), 'never named after the plaintext title');
});
atest('New Chat reuses an empty chat known only by its index row (NEWCHAT-REUSE)', async () => {
  const m = load(piece('  async function newChat() {', '  function renameEntry'), ['newChat']);
  const st = memStore();
  m.setup({ store: st, entries: [{ key: 'X', id: 'X', encrypted: false, loaded: false, conversation: null, row: { id: 'X', title: 'New Chat', messageCount: 0, encrypted: false } }] });
  await m.newChat();
  assert.deepEqual(same(m.selected), ['X']);
  assert.equal(st.rows.size, 0, 'nothing new was written');
  m.setup({ entries: [{ key: 'Y', id: 'Y', encrypted: false, loaded: false, conversation: null, row: { id: 'Y', title: 'New Chat', messageCount: 2, encrypted: false } },
    { key: 'Z', id: 'Z', encrypted: true, loaded: false, conversation: null, row: { id: 'Z', title: 'Encrypted conversation', messageCount: null, encrypted: true } }] });
  await m.newChat();
  assert.equal(st.rows.size, 1, 'a used or encrypted row is not reused');
});
test('a row removed in another tab keeps open dialogs, except the settings of that conversation (DISCARD-DIALOGS)', () => {
  const m = load(piece('  function discardEntry(entry) {', '  async function loadEntry'), ['discardEntry']);
  const other = { id: 'O', run: null, saveTimer: 0 }, mine = { id: 'M', run: null, saveTimer: 0 };
  m.setup({ entries: [other, mine], dialogEntry: mine });
  m.discardEntry(other);
  assert.deepEqual(same(m.dropped), [['O', true]], 'dialogs kept');
  assert.equal(m.convDialog.closed, 0);
  m.discardEntry(mine);
  assert.equal(m.convDialog.closed, 1, 'the settings of the removed conversation close');
});
test('a reload from another tab closes that conversation\'s settings and keeps the caret (RELOAD-SETTINGS-FOCUS)', () => {
  const m = load(piece('  function reloadEntry(', '  /** Brings the index row'), ['reloadEntry']);
  const input = { selectionStart: 3, selectionEnd: 5 };
  const entry = { key: 'M', id: 'M', view: { composer: { input } }, keyInfo: null };
  m.setup({ entries: [entry], dialogEntry: entry, selectedKey: 'M', active: null });
  m.reloadEntry(entry);
  assert.equal(m.convDialog.closed, 1, 'its edits would go to a dropped object');
  assert.equal(entry.refocus, null, 'composer not focused: nothing to restore');
  const typing = { key: 'N', id: 'N', view: { composer: { input } }, keyInfo: null };
  m.setup({ entries: [typing], dialogEntry: null, selectedKey: 'N', active: input });
  m.reloadEntry(typing);
  assert.deepEqual(same(typing.refocus), { start: 3, end: 5 });
  assert.equal(m.convDialog.closed, 1, 'another conversation\'s settings stay open');
  assert.ok(page.includes('if (entry.refocus) {') && page.includes('input.setSelectionRange(start, end)'), 'the rebuilt composer takes focus again');
  assert.ok(page.includes('entry.loaded && !entry.run && !entry.saveTimer) reloadEntry(entry)'), 'unsaved local changes are not dropped by a reload');
});
atest('a tab streaming into a conversation another tab encrypted stops saving, says so once, and reopens it locked (ENCRYPTED-ELSEWHERE)', async () => {
  const m = load(`const syncRow = () => {}; const reloadEntry = e => { e.reloaded = true; };` + piece('  async function writeEntry(', '  function touch(entry)'), ['writeEntry']);
  let finish;
  const entry = { id: 'E', encrypted: false, keyInfo: null, discarded: false, conversation: { id: 'E' }, run: {}, runDone: new Promise(r => { finish = r; }) };
  const refused = Object.assign(new Error('An encrypted conversation with this id exists'), { code: 'wouldDecrypt' });
  m.setup({ store: { put: async () => { throw refused; }, list: async () => [] } });
  await m.writeEntry(entry); await m.writeEntry(entry);
  assert.deepEqual(same(m.toasts), ['storageError'], 'one toast, not one per autosave');
  assert.equal(entry.encryptedElsewhere, true);
  entry.run = null; finish();
  await new Promise(r => setTimeout(r, 5));
  assert.equal(entry.encrypted, true);
  assert.equal(entry.reloaded, true);
  assert.equal(entry.encryptedElsewhere, false);
  assert.ok(page.includes('entry.saveTimer || entry.encryptedElsewhere) return;'), 'scheduleSave honours the flag');
});

for (const [name, fn] of later) {
  try { await fn(); passed++; } catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message}`); }
}

console.log(failures ? `page: ${failures} failed, ${passed} passed` : `page: all ${passed} passed`);
process.exit(failures ? 1 : 0);
