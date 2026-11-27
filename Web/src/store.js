// Parley Web storage: conversations, servers and settings in IndexedDB, plus export and import in
// Parley's file format. No DOM. The IndexedDB factory is passed in so tests can use a small
// in-memory stand-in, and so the page can fall back to memory when the browser refuses storage.
// File encryption itself lives in ParleyCore (Reader/src/core.js); this module only calls it.
const ParleyStore = (() => {
  'use strict';

  const DB_NAME = 'parley-web';
  const DB_VERSION = 2;
  const CONVERSATIONS = 'conversations';
  // One row per conversation without its body (images and ciphertext can be megabytes), so the list
  // never reads bodies. Added in version 2; written together with the conversation in one transaction.
  const INDEX = 'index';
  const PROVIDERS = 'providers';
  const SETTINGS = 'settings';
  const CHANNEL_NAME = 'parley-web';
  /**
   * Shown in the list for an encrypted conversation. The Mac app's encrypted file header holds only
   * the id, so the title is not kept in the clear here either; the page may show the real title
   * while the conversation is unlocked in memory.
   */
  const ENCRYPTED_TITLE = 'Encrypted conversation';

  function core(options) {
    const c = (options && options.core) || globalThis.ParleyCore;
    if (!c) throw new Error('ParleyCore is not loaded');
    return c;
  }

  function nowISO() {
    return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  }

  // ---- Backends: the same four calls over IndexedDB or a Map ----

  function requestResult(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IndexedDB request failed'));
    });
  }

  function wouldDecryptError() {
    const e = new Error('An encrypted conversation with this id exists; pass overwriteEncrypted to replace it');
    e.code = 'wouldDecrypt';
    return e;
  }
  const indexRowOf = ({ body, ...row }) => row;

  function idbBackend(db) {
    // Writes resolve when the transaction commits, not when the request succeeds.
    function run(storeName, mode, fn) {
      return new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction([storeName], mode); } catch (e) { reject(e); return; }
        let result;
        tx.oncomplete = () => resolve(result);
        tx.onerror = () => reject(tx.error || new Error('IndexedDB transaction failed'));
        tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction aborted'));
        const request = fn(tx.objectStore(storeName));
        request.onsuccess = () => { result = request.result; };
      });
    }
    return {
      kind: 'indexedDB',
      getAll: name => run(name, 'readonly', s => s.getAll()),
      get: (name, key) => run(name, 'readonly', s => s.get(key)),
      put: (name, value) => run(name, 'readwrite', s => s.put(value)),
      delete: (name, key) => run(name, 'readwrite', s => s.delete(key)),
      /** Writes a conversation row and its index row in one transaction. With `plainOnly`, an encrypted row with this id is checked for and kept in the same transaction. */
      putConversation: (row, plainOnly) => new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction([CONVERSATIONS, INDEX], 'readwrite'); } catch (e) { reject(e); return; }
        let failure = null;
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error || new Error('IndexedDB transaction failed'));
        tx.onabort = () => reject(failure || tx.error || new Error('IndexedDB transaction aborted'));
        const write = () => { tx.objectStore(CONVERSATIONS).put(row); tx.objectStore(INDEX).put(indexRowOf(row)); };
        if (!plainOnly) { write(); return; }
        const existing = tx.objectStore(CONVERSATIONS).get(row.id);
        existing.onsuccess = () => {
          if (existing.result && existing.result.encrypted) { failure = wouldDecryptError(); try { tx.abort(); } catch (_) { reject(failure); } } else write();
        };
      }),
      deleteConversation: key => new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction([CONVERSATIONS, INDEX], 'readwrite'); } catch (e) { reject(e); return; }
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error || new Error('IndexedDB transaction failed'));
        tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction aborted'));
        tx.objectStore(CONVERSATIONS).delete(key);
        tx.objectStore(INDEX).delete(key);
      }),
      close: () => { try { db.close(); } catch (_) { /* already closed */ } },
    };
  }

  function memoryBackend() {
    const tables = { [CONVERSATIONS]: new Map(), [INDEX]: new Map(), [PROVIDERS]: new Map(), [SETTINGS]: new Map() };
    const keyOf = { [CONVERSATIONS]: 'id', [INDEX]: 'id', [PROVIDERS]: 'id', [SETTINGS]: 'key' };
    const copy = v => (v === undefined ? v : structuredClone(v));
    return {
      kind: 'memory',
      getAll: async name => [...tables[name].values()].map(copy),
      get: async (name, key) => copy(tables[name].get(key)),
      put: async (name, value) => { tables[name].set(value[keyOf[name]], copy(value)); },
      delete: async (name, key) => { tables[name].delete(key); },
      putConversation: async (row, plainOnly) => {
        const existing = tables[CONVERSATIONS].get(row.id);
        if (plainOnly && existing && existing.encrypted) throw wouldDecryptError();
        tables[CONVERSATIONS].set(row.id, copy(row));
        tables[INDEX].set(row.id, copy(indexRowOf(row)));
      },
      deleteConversation: async key => { tables[CONVERSATIONS].delete(key); tables[INDEX].delete(key); },
      close: () => {},
    };
  }

  function openDatabase(factory) {
    return new Promise((resolve, reject) => {
      if (!factory) { reject(new Error('IndexedDB is not available')); return; }
      let request;
      try { request = factory.open(DB_NAME, DB_VERSION); } catch (e) { reject(e); return; }
      request.onupgradeneeded = () => {
        const db = request.result;
        const has = name => db.objectStoreNames.contains(name);
        const hadConversations = has(CONVERSATIONS);
        if (!hadConversations) db.createObjectStore(CONVERSATIONS, { keyPath: 'id' });
        if (!has(INDEX)) {
          db.createObjectStore(INDEX, { keyPath: 'id' });
          // Version 1 had no index: build it once from the stored conversations; nothing is removed.
          if (hadConversations) {
            const tx = request.transaction;
            const all = tx.objectStore(CONVERSATIONS).getAll();
            all.onsuccess = () => { for (const row of all.result) tx.objectStore(INDEX).put(indexRowOf(row)); };
          }
        }
        if (!has(PROVIDERS)) db.createObjectStore(PROVIDERS, { keyPath: 'id' });
        if (!has(SETTINGS)) db.createObjectStore(SETTINGS, { keyPath: 'key' });
      };
      let settled = false;
      request.onsuccess = () => {
        const db = request.result;
        if (settled) { try { db.close(); } catch (_) { /* ignore */ } return; } // rejected as blocked earlier: do not leak it
        settled = true;
        // Release the connection when a newer version of the page wants to upgrade the database.
        db.onversionchange = () => { try { db.close(); } catch (_) { /* ignore */ } };
        resolve(db);
      };
      request.onerror = () => { if (!settled) { settled = true; reject(request.error || new Error('Could not open IndexedDB')); } };
      request.onblocked = () => { if (!settled) { settled = true; reject(new Error('IndexedDB is blocked by another tab')); } };
    });
  }

  // ---- The store ----

  function makeStore(backend, options) {
    const opts = options || {};
    const Channel = opts.broadcast !== undefined ? opts.broadcast : globalThis.BroadcastChannel;
    const listeners = new Set();
    // The page keeps a key for the session unless the user chose "Remember in this browser".
    const sessionKeys = new Map();
    let channel = null;
    try {
      if (Channel) {
        channel = new Channel(CHANNEL_NAME);
        channel.onmessage = event => {
          const data = event && event.data;
          if (data && typeof data.id === 'string') for (const fn of listeners) fn(data);
        };
      }
    } catch (_) { channel = null; }

    function announce(type, id) {
      if (!channel) return;
      try { channel.postMessage({ type, id }); } catch (_) { /* a closed channel is not an error */ }
    }

    function indexOf(conversation, encrypted) {
      if (encrypted) {
        // No title, count or content-derived date: only what the file itself shows, plus the save time to order the list.
        return { id: conversation.id.toUpperCase(), title: ENCRYPTED_TITLE, updatedAt: nowISO(), encrypted: true, messageCount: null };
      }
      return {
        id: conversation.id.toUpperCase(),
        title: conversation.title || 'Untitled',
        updatedAt: conversation.updatedAt || nowISO(),
        encrypted: false,
        messageCount: conversation.messages.length,
      };
    }

    const store = {
      backend: backend.kind,

      /** Index rows, newest first, without bodies. */
      async list() {
        const rows = await backend.getAll(INDEX);
        return rows
          .map(({ id, title, updatedAt, encrypted, messageCount }) => ({ id, title, updatedAt, encrypted, messageCount }))
          .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0));
      },

      /** `{kind:'plain', conversation}`, `{kind:'encrypted', header, text}` (then ParleyCore.decrypt), or null. */
      async get(id) {
        const row = await backend.get(CONVERSATIONS, String(id).toUpperCase());
        if (!row) return null;
        if (!row.encrypted) return { kind: 'plain', conversation: row.body };
        return { kind: 'encrypted', header: core(opts).parseFile(row.body), text: row.body };
      },

      /** Saves a conversation; encrypted with `key` (ParleyCore key info) when given, plain otherwise. */
      async put(conversation, putOptions) {
        const key = putOptions && putOptions.key;
        const encrypted = !!key;
        // Plain over encrypted would silently turn ciphertext into plaintext: checked in the writing transaction.
        const plainOnly = !encrypted && !(putOptions && putOptions.overwriteEncrypted);
        const body = encrypted ? await core(opts).encryptFile(conversation, key) : conversation;
        const row = { ...indexOf(conversation, encrypted), body };
        await backend.putConversation(row, plainOnly);
        announce('saved', row.id);
        return row.id;
      },

      /** Saves an imported file as it is: plain ones as conversations, encrypted ones still locked. */
      async putFile(text) {
        const parsed = core(opts).parseFile(text);
        if (parsed.kind === 'plain') return store.put(parsed.conversation);
        const row = { id: parsed.id, title: ENCRYPTED_TITLE, updatedAt: nowISO(), encrypted: true, messageCount: null, body: text };
        await backend.putConversation(row, false);
        announce('saved', row.id);
        return row.id;
      },

      async remove(id) {
        const key = String(id).toUpperCase();
        await backend.deleteConversation(key);
        announce('removed', key);
      },

      /** Parley's file text for a conversation: encrypted when a key is given. */
      async exportFile(conversation, key) {
        return key ? core(opts).encryptFile(conversation, key) : core(opts).encodePlainFile(conversation);
      },

      /** `{kind:'plain', conversation}` or `{kind:'encrypted', header}`; throws ParleyCore.ReaderError. */
      importFile(text) {
        const parsed = core(opts).parseFile(text);
        if (parsed.kind === 'plain') return { kind: 'plain', conversation: parsed.conversation };
        return { kind: 'encrypted', header: parsed, text };
      },

      providers: {
        async list() {
          const rows = await backend.getAll(PROVIDERS);
          return rows.map(row => (sessionKeys.has(row.id) && !row.apiKey ? { ...row, apiKey: sessionKeys.get(row.id) } : row));
        },
        /** The key goes to disk only when `rememberKey` is true; otherwise it stays in memory. */
        async put(provider) {
          if (!provider || typeof provider.id !== 'string' || !provider.id) throw new Error('A provider needs an id');
          const row = { ...provider };
          // No apiKey field means "unchanged" (a rename); an explicit empty one clears it.
          if (row.apiKey) sessionKeys.set(row.id, row.apiKey); else if ('apiKey' in provider) sessionKeys.delete(row.id);
          if (!row.rememberKey) delete row.apiKey;
          await backend.put(PROVIDERS, row);
        },
        async remove(id) {
          sessionKeys.delete(id);
          await backend.delete(PROVIDERS, id);
        },
      },

      settings: {
        async get(key, fallback) {
          const row = await backend.get(SETTINGS, key);
          return row ? row.value : fallback;
        },
        async set(key, value) {
          if (typeof key !== 'string' || !key) throw new Error('A setting needs a key');
          await backend.put(SETTINGS, { key, value });
        },
      },

      /** Writes, reads back and deletes a test record: `{ok: true}` or `{ok: false, error}`. */
      async probe() {
        const key = '__probe__';
        const value = Math.random().toString(36).slice(2);
        try {
          await backend.put(SETTINGS, { key, value });
          const row = await backend.get(SETTINGS, key);
          await backend.delete(SETTINGS, key);
          if (!row || row.value !== value) return { ok: false, error: 'The test record was not read back.' };
          return { ok: true };
        } catch (e) {
          return { ok: false, error: String((e && e.message) || e) };
        }
      },

      /** Asks the browser not to evict this origin's storage. `{supported, granted}`. */
      async requestPersistence() {
        const storage = opts.storageManager || (globalThis.navigator && globalThis.navigator.storage);
        if (!storage || typeof storage.persist !== 'function') return { supported: false, granted: false };
        try {
          const already = typeof storage.persisted === 'function' ? await storage.persisted() : false;
          return { supported: true, granted: already || !!(await storage.persist()) };
        } catch (_) {
          return { supported: true, granted: false };
        }
      },

      /** Calls fn({type, id}) when another tab saved or removed a conversation. Returns an unsubscribe function. */
      onChange(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
      },

      close() {
        listeners.clear();
        if (channel) { try { channel.close(); } catch (_) { /* ignore */ } channel = null; }
        backend.close();
      },
    };
    return store;
  }

  /** Opens `parley-web`. Rejects when storage is unavailable; use `probe` first or fall back to `memory()`. */
  async function open(indexedDB, options) {
    return makeStore(idbBackend(await openDatabase(indexedDB)), options);
  }

  /** A store that lives only in this page, for when the browser refuses storage. */
  function memory(options) {
    return makeStore(memoryBackend(), options);
  }

  /** Opens, writes and reads a test record. `{ok, store}` or `{ok: false, error}`; the caller keeps the store. */
  async function probe(indexedDB, options) {
    let store;
    try {
      store = await open(indexedDB, options);
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
    const result = await store.probe();
    if (!result.ok) { store.close(); return result; }
    return { ok: true, store };
  }

  return { DB_NAME, DB_VERSION, CHANNEL_NAME, ENCRYPTED_TITLE, open, memory, probe };
})();
if (typeof globalThis !== 'undefined') globalThis.ParleyStore = ParleyStore;
