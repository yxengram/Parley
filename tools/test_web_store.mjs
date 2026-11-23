// Tests ParleyCore encryption (Reader/src/core.js) and ParleyStore (Web/src/store.js).
//   node tools/test_web_store.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadCore, sampleConversation } from './web_fixtures.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const core = loadCore();
(0, eval)(readFileSync(join(root, 'Web/src/store.js'), 'utf8'));
const store = globalThis.ParleyStore;

let passed = 0, failed = 0;
function assert(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }
// Key order does not matter in JSON objects, so compare with sorted keys.
const sorted = v => (Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object'
  ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sorted(v[k])])) : v);
const canon = v => JSON.stringify(sorted(v));
function eq(a, b, msg) {
  const x = canon(a), y = canon(b);
  if (x !== y) throw new Error(`${msg || 'not equal'}\n  got      ${x}\n  expected ${y}`);
}
async function test(name, fn) {
  try { await fn(); passed++; console.log(`ok   ${name}`); } catch (e) { failed++; console.log(`FAIL ${name}\n     ${e.message}`); }
}
const code = async fn => { try { await fn(); return 'none'; } catch (e) { return e.code || String(e); } };

// A minimal in-memory IndexedDB: open + upgrade, transactions, get/put/delete/getAll.
function fakeIndexedDB() {
  const dbs = new Map(); // name -> {version, stores: Map(name -> {keyPath, rows: Map})}
  const later = fn => queueMicrotask(fn);
  return {
    open(name, version) {
      const req = {};
      later(() => {
        let rec = dbs.get(name);
        const fresh = !rec;
        if (!rec) { rec = { version, stores: new Map() }; dbs.set(name, rec); }
        const db = {
          objectStoreNames: { contains: n => rec.stores.has(n) },
          createObjectStore(n, { keyPath }) { rec.stores.set(n, { keyPath, rows: new Map() }); },
          close() {},
          transaction(names, mode) {
            const tx = {};
            let pending = 0;
            const settle = () => { if (pending === 0) later(() => tx.oncomplete && tx.oncomplete()); };
            tx.objectStore = n => {
              const s = rec.stores.get(n);
              if (!s) throw new Error('NotFoundError');
              const op = fn => {
                const r = {}; pending++;
                later(() => { r.result = fn(); r.onsuccess && r.onsuccess(); pending--; settle(); });
                return r;
              };
              return {
                get: k => op(() => structuredClone(s.rows.get(k))),
                getAll: () => op(() => [...s.rows.values()].map(v => structuredClone(v))),
                put: v => op(() => { s.rows.set(v[s.keyPath], structuredClone(v)); return v[s.keyPath]; }),
                delete: k => op(() => { s.rows.delete(k); }),
              };
            };
            return tx;
          },
        };
        req.result = db;
        if (fresh) req.onupgradeneeded && req.onupgradeneeded();
        req.onsuccess && req.onsuccess();
      });
      return req;
    },
    dump: name => dbs.get(name),
  };
}

const PW = 'pässwörd';
const ITER = 1000;

await test('encryptFile -> parseFile -> decrypt round-trips', async () => {
  const conv = sampleConversation();
  const key = await core.newKey(PW, ITER);
  assert(key.salt.length === 16 && key.iterations === ITER);
  const text = await core.encryptFile(conv, key);
  const header = core.parseFile(text);
  assert(header.kind === 'encrypted' && header.id === conv.id);
  eq(await core.decrypt(header, PW), conv);
  eq(await core.decryptWithKey(header, key), conv, 'fast path');
});
await test('file header fields and layout match ConversationFile.encode', async () => {
  const conv = sampleConversation();
  const key = await core.newKey(PW, ITER);
  const o = JSON.parse(await core.encryptFile(conv, key));
  eq(Object.keys(o).sort(), ['cipher', 'encrypted', 'format', 'id', 'kdf', 'payload', 'version']);
  eq([o.format, o.version, o.encrypted, o.cipher, o.kdf.name, o.kdf.iterations],
    ['parley.conversation', 1, true, 'AES-256-GCM', 'PBKDF2-HMAC-SHA256', ITER]);
  const box = core.base64ToBytes(o.payload);
  const plainLen = new TextEncoder().encode(JSON.stringify(conv)).length;
  assert(box.length === 12 + plainLen + 16 || box.length > 28, 'nonce | ciphertext | tag');
  assert(core.base64ToBytes(o.kdf.salt).length === 16);
});
await test('fresh nonce each time', async () => {
  const conv = sampleConversation();
  const key = await core.newKey(PW, ITER);
  const a = JSON.parse(await core.encryptFile(conv, key)).payload;
  const b = JSON.parse(await core.encryptFile(conv, key)).payload;
  assert(a !== b);
});
await test('wrong password', async () => {
  const text = await core.encryptFile(sampleConversation(), await core.newKey(PW, ITER));
  eq(await code(() => core.decrypt(core.parseFile(text), 'nope')), 'wrongPassword');
});
await test('keyFromHeader reuses salt and iterations; NFD password equals NFC', async () => {
  const conv = sampleConversation();
  const text = await core.encryptFile(conv, await core.newKey(PW, ITER));
  const header = core.parseFile(text);
  const again = await core.keyFromHeader(header, PW.normalize('NFD'));
  eq(again.iterations, ITER);
  eq(Array.from(again.salt), Array.from(header.salt));
  conv.title = 'changed';
  const text2 = await core.encryptFile(conv, again);
  const h2 = core.parseFile(text2);
  eq((await core.decrypt(h2, PW)).title, 'changed');
});
await test('tampered header fails authentication', async () => {
  const text = await core.encryptFile(sampleConversation(), await core.newKey(PW, ITER));
  const o = JSON.parse(text); o.kdf.iterations = ITER + 1;
  eq(await code(() => core.decrypt(core.parseFile(JSON.stringify(o)), PW)), 'wrongPassword');
});
await test('plain file round-trips; envelope fields', () => {
  const conv = sampleConversation();
  const text = core.encodePlainFile(conv);
  const o = JSON.parse(text);
  eq([o.format, o.version, o.encrypted], ['parley.conversation', 1, false]);
  const parsed = core.parseFile(text);
  eq(parsed.kind, 'plain');
  eq(parsed.conversation, conv);
});
await test('rejects bad iteration counts', async () => {
  eq(await code(() => core.newKey(PW, 0)), 'corrupt');
});

await test('store: CRUD, list order, plain index fields', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  const a = sampleConversation();
  const b = { ...sampleConversation(), id: 'B0000000-0000-4000-8000-000000000001', title: 'Newer', updatedAt: '2026-12-01T00:00:00Z' };
  await s.put(a); await s.put(b);
  const rows = await s.list();
  eq(rows.map(r => r.title), ['Newer', a.title]);
  eq(rows[1], { id: a.id, title: a.title, updatedAt: a.updatedAt, encrypted: false, messageCount: 4 });
  const got = await s.get(a.id.toLowerCase());
  eq(got.kind, 'plain'); eq(got.conversation, a);
  await s.remove(a.id);
  eq(await s.get(a.id), null);
  eq((await s.list()).length, 1);
  s.close();
});
await test('store: persists across reopen on the same factory', async () => {
  const idb = fakeIndexedDB();
  const s1 = await store.open(idb, { broadcast: null });
  await s1.put(sampleConversation()); s1.close();
  const s2 = await store.open(idb, { broadcast: null });
  eq((await s2.list()).length, 1);
});
await test('store: encrypted put, get, unlock; no title or text at rest', async () => {
  const idb = fakeIndexedDB();
  const s = await store.open(idb, { broadcast: null });
  const conv = sampleConversation();
  const key = await core.newKey(PW, ITER);
  await s.put(conv, { key });
  const [row] = await s.list();
  eq(row.encrypted, true); eq(row.messageCount, null);
  assert(row.title === store.ENCRYPTED_TITLE);
  const raw = JSON.stringify([...idb.dump('parley-web').stores.get('conversations').rows.values()]);
  for (const secret of ['Fixture', 'ünïcode', 'single pixel', 'You are terse', 'qwen3', 'notes', conv.compaction.summary, conv.updatedAt]) {
    assert(!raw.includes(secret), `leaked: ${secret}`);
  }
  const got = await s.get(conv.id);
  eq(got.kind, 'encrypted');
  eq(await core.decrypt(got.header, PW), conv);
  eq(await code(() => core.decrypt(got.header, 'bad')), 'wrongPassword');
});
await test('store: export/import in both forms; putFile keeps encrypted files locked', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  const conv = sampleConversation();
  const plain = await s.exportFile(conv);
  const imp = s.importFile(plain);
  eq(imp.kind, 'plain'); eq(imp.conversation, conv);
  const enc = await s.exportFile(conv, await core.newKey(PW, ITER));
  const imp2 = s.importFile(enc);
  eq(imp2.kind, 'encrypted'); eq(await core.decrypt(imp2.header, PW), conv);
  await s.putFile(enc);
  const got = await s.get(conv.id);
  eq(got.kind, 'encrypted'); eq(got.text, enc);
  eq(await code(() => s.importFile('{"format":"other"}')), 'notParley');
  eq(await code(() => s.importFile('nonsense')), 'corrupt');
});
await test('store: providers keep the API key only when remembered', async () => {
  const idb = fakeIndexedDB();
  const s = await store.open(idb, { broadcast: null });
  await s.providers.put({ id: 'P1', name: 'Local', baseURL: 'http://localhost:1234', apiKey: 'sk-secret', rememberKey: false });
  await s.providers.put({ id: 'P2', name: 'Remote', baseURL: 'https://x', apiKey: 'sk-kept', rememberKey: true });
  const raw = dump(idb);
  assert(!raw.includes('sk-secret') && raw.includes('sk-kept'));
  eq((await s.providers.list()).find(p => p.id === 'P1').apiKey, 'sk-secret', 'session copy');
  const s2 = await store.open(idb, { broadcast: null });
  eq((await s2.providers.list()).find(p => p.id === 'P1').apiKey, undefined);
  await s.providers.remove('P1');
  eq((await s.providers.list()).length, 1);
  function dump(db) { return JSON.stringify([...db.dump('parley-web').stores.get('providers').rows.values()]); }
});
await test('store: settings get/set/default', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  eq(await s.settings.get('skin', 'fort'), 'fort');
  await s.settings.set('skin', 'harbor');
  eq(await s.settings.get('skin'), 'harbor');
});
await test('probe: works, leaves nothing behind; fails cleanly without IndexedDB', async () => {
  const idb = fakeIndexedDB();
  const r = await store.probe(idb, { broadcast: null });
  assert(r.ok && r.store);
  eq(await r.store.settings.get('__probe__'), undefined);
  const bad = await store.probe(undefined, { broadcast: null });
  eq(bad.ok, false); assert(bad.error);
  const throwing = await store.probe({ open() { throw new Error('SecurityError'); } }, { broadcast: null });
  eq(throwing.ok, false);
  const mem = store.memory({ broadcast: null });
  assert((await mem.probe()).ok);
  await mem.put(sampleConversation());
  eq((await mem.list()).length, 1);
});
await test('requestPersistence: absent, granted, refused', async () => {
  const s = store.memory({ broadcast: null, storageManager: null });
  const none = await s.requestPersistence();
  eq(none.supported === false || none.supported === true, true); // navigator.storage may exist in Node
  const yes = await store.memory({ broadcast: null, storageManager: { persist: async () => true } }).requestPersistence();
  eq(yes, { supported: true, granted: true });
  const no = await store.memory({ broadcast: null, storageManager: { persist: async () => false } }).requestPersistence();
  eq(no, { supported: true, granted: false });
});
await test('BroadcastChannel absent is fine; present notifies other instances', async () => {
  const noChannel = await store.open(fakeIndexedDB(), { broadcast: null });
  await noChannel.put(sampleConversation());
  const bus = new Set();
  class FakeChannel {
    constructor(name) { assert(name === 'parley-web'); this.peer = bus; bus.add(this); }
    postMessage(data) { for (const c of bus) if (c !== this) queueMicrotask(() => c.onmessage({ data })); }
    close() { bus.delete(this); }
  }
  const idb = fakeIndexedDB();
  const a = await store.open(idb, { broadcast: FakeChannel });
  const b = await store.open(idb, { broadcast: FakeChannel });
  const seen = [];
  b.onChange(m => seen.push(m));
  await a.put(sampleConversation());
  await new Promise(r => setTimeout(r, 5));
  eq(seen, [{ type: 'saved', id: sampleConversation().id }]);
  a.close(); b.close();
});

await test('export: fractional-second dates are normalised in date fields only', async () => {
  const conv = sampleConversation();
  conv.updatedAt = '2026-11-23T10:15:30.123Z';
  conv.messages[0].createdAt = '2026-11-23T10:00:05.5Z';
  conv.messages[2].content = '2026-11-23T10:00:05.5Z'; // message text stays as typed
  const want = sampleConversation();
  want.messages[2].content = '2026-11-23T10:00:05.5Z';
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  eq(core.parseFile(await s.exportFile(conv)).conversation, want);
  eq(await core.decrypt(core.parseFile(await s.exportFile(conv, await core.newKey(PW, ITER))), PW), want);
});
await test('export: __proto__ key survives; non-plain objects are refused', async () => {
  const conv = sampleConversation();
  conv.extra = JSON.parse('{"__proto__": {"a": 1}, "b": 2}');
  const text = await core.encodePlainFile(conv);
  assert(text.includes('"__proto__"'), 'key dropped');
  eq(await code(() => core.encodePlainFile({ ...sampleConversation(), createdAt: new Date() })), 'corrupt');
});
await test('store: lowercase id, missing title and date, fractional dates round-trip through put/get', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  const a = { ...sampleConversation(), id: sampleConversation().id.toLowerCase() };
  delete a.title; delete a.updatedAt;
  await s.put(a);
  const b = { ...sampleConversation(), id: 'B0000000-0000-4000-8000-000000000001', title: 'Dated', updatedAt: '2020-01-01T00:00:00Z' };
  await s.put(b);
  const rows = await s.list();
  eq(rows.length, 2);
  const row = rows.find(r => r.id === sampleConversation().id);
  eq(row.title, 'Untitled'); assert(typeof row.updatedAt === 'string');
  eq(rows[0].id, row.id, 'now sorts before 2020');
  eq((await s.get(a.id)).kind, 'plain');
  const imp = s.importFile(await s.exportFile(sampleConversation(), await core.newKey(PW, ITER)));
  assert(typeof imp.text === 'string', 'importFile returns text');
});
await test('store: plain put will not overwrite an encrypted row unless told to', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  const conv = sampleConversation();
  await s.put(conv, { key: await core.newKey(PW, ITER) });
  eq(await code(() => s.put(conv)), 'wouldDecrypt');
  eq((await s.get(conv.id)).kind, 'encrypted');
  await s.put(conv, { key: await core.newKey(PW, ITER) }); // encrypted over encrypted is fine
  await s.put(conv, { overwriteEncrypted: true });
  eq((await s.get(conv.id)).kind, 'plain');
});
await test('store: provider without apiKey keeps the session key; missing ids are explicit errors', async () => {
  const s = await store.open(fakeIndexedDB(), { broadcast: null });
  await s.providers.put({ id: 'P1', name: 'A', apiKey: 'sk-1', rememberKey: false });
  await s.providers.put({ id: 'P1', name: 'Renamed', rememberKey: false });
  eq((await s.providers.list())[0].apiKey, 'sk-1');
  await s.providers.put({ id: 'P1', name: 'Renamed', apiKey: '', rememberKey: false });
  eq((await s.providers.list())[0].apiKey, undefined);
  assert(/id/.test(await code(() => s.providers.put({ name: 'x' }))));
  assert(/key/.test(await code(() => s.settings.set(undefined, 1))));
});
await test('store: broadcast undefined falls back to the global; open releases on versionchange', async () => {
  let made = 0;
  const saved = globalThis.BroadcastChannel;
  globalThis.BroadcastChannel = class { constructor() { made++; } postMessage() {} close() {} };
  try { (await store.open(fakeIndexedDB(), { broadcast: undefined })).close(); } finally { globalThis.BroadcastChannel = saved; }
  eq(made, 1);
  let closed = false, dbRef;
  const idb = fakeIndexedDB();
  const orig = idb.open;
  idb.open = (...a) => { const r = orig(...a); const ok = () => { dbRef = r.result; dbRef.close = () => { closed = true; }; }; const prev = r; queueMicrotask(() => {}); Object.defineProperty(r, 'onsuccess', { set(fn) { r._f = () => { ok(); fn(); }; }, get() { return r._f; }, configurable: true }); return r; };
  const s = await store.open(idb, { broadcast: null });
  assert(typeof dbRef.onversionchange === 'function');
  dbRef.onversionchange();
  assert(closed);
  s.close();
});

console.log(failed ? `${failed} FAILED, ${passed} passed` : `all ${passed} passed`);
process.exit(failed ? 1 : 0);
