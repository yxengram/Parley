// Parley Reader core: reads Parley conversation files, plain or encrypted. No DOM, no network.
// The rules mirror Sources/ParleyCore/ConversationFile.swift and Crypto.swift; see DESIGN.md
// "Encryption decision". Runs in the page and, for tests, in Node (tools/test_reader.mjs).
const ParleyCore = (() => {
  'use strict';

  const FORMAT = 'parley.conversation';
  const VERSION = 1;
  const KDF_NAME = 'PBKDF2-HMAC-SHA256';
  const CIPHER_NAME = 'AES-256-GCM';
  /** Same cap as Parley's: a hostile header must not make the page spin for minutes. */
  const MAX_ITERATIONS = 50000000;
  const NONCE_BYTES = 12;
  const TAG_BYTES = 16;
  const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
  // Checked as a length rule plus one flat character class: a regex with a repeated group
  // backtracks per group and fails (stack overflow, or a silent false) on payloads of a few MB.
  const B64_CHARS_RE = /^[A-Za-z0-9+/]*={0,2}$/;

  /** Errors carry a code the page turns into words; messages never quote file content. */
  class ReaderError extends Error {
    constructor(code, detail) {
      super(detail ? `${code}: ${detail}` : code);
      this.name = 'ReaderError';
      this.code = code;
      this.detail = detail || '';
    }
  }

  /** Strict standard base64, like Foundation's Data(base64Encoded:) without options. */
  function base64ToBytes(text) {
    if (typeof text !== 'string' || text.length % 4 !== 0 || !B64_CHARS_RE.test(text)) return null;
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function bytesToBase64(bytes) {
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  /**
   * Parses a file's text. Returns {kind: 'plain', conversation} or
   * {kind: 'encrypted', id, iterations, salt, payload}. Throws ReaderError with the same
   * order of checks as Parley: invalid JSON, not a conversation file, version, fields.
   */
  function parseFile(text) {
    let object;
    try {
      object = JSON.parse(text);
    } catch (_) {
      throw new ReaderError('corrupt', 'invalid JSON');
    }
    if (!isObject(object) || object.format !== FORMAT) throw new ReaderError('notParley');
    if (typeof object.version !== 'number' || !Number.isInteger(object.version)) {
      throw new ReaderError('corrupt', 'missing version');
    }
    if (object.version !== VERSION) throw new ReaderError('unsupportedVersion', String(object.version));
    if (typeof object.encrypted !== 'boolean') throw new ReaderError('corrupt', 'missing encryption flag');

    if (!object.encrypted) {
      return { kind: 'plain', conversation: checkConversation(object.conversation) };
    }

    const kdf = object.kdf;
    if (typeof object.id !== 'string' || !isObject(kdf) || typeof kdf.name !== 'string'
        || typeof kdf.salt !== 'string' || typeof object.cipher !== 'string'
        || typeof object.payload !== 'string' || typeof kdf.iterations !== 'number') {
      throw new ReaderError('corrupt', 'invalid encrypted header');
    }
    if (!UUID_RE.test(object.id)) throw new ReaderError('corrupt', 'invalid conversation id');
    if (kdf.name !== KDF_NAME) throw new ReaderError('corrupt', 'unsupported key derivation function');
    if (object.cipher !== CIPHER_NAME) throw new ReaderError('corrupt', 'unsupported cipher');
    if (!Number.isInteger(kdf.iterations) || kdf.iterations <= 0 || kdf.iterations > MAX_ITERATIONS) {
      throw new ReaderError('corrupt', 'invalid iteration count');
    }
    const salt = base64ToBytes(kdf.salt);
    if (!salt || salt.length === 0) throw new ReaderError('corrupt', 'invalid salt');
    const payload = base64ToBytes(object.payload);
    if (!payload) throw new ReaderError('corrupt', 'invalid payload encoding');
    return { kind: 'encrypted', id: object.id.toUpperCase(), iterations: kdf.iterations, salt, payload };
  }

  /** The minimum the page relies on. Parley's decoder is stricter; extra or missing optional keys are fine. */
  function checkConversation(c) {
    if (!isObject(c) || typeof c.id !== 'string' || !UUID_RE.test(c.id) || !Array.isArray(c.messages)) {
      throw new ReaderError('corrupt', 'invalid conversation data');
    }
    for (const m of c.messages) {
      if (!isObject(m) || typeof m.role !== 'string' || typeof m.content !== 'string') {
        throw new ReaderError('corrupt', 'invalid conversation data');
      }
    }
    return c;
  }

  function subtle() {
    const s = globalThis.crypto && globalThis.crypto.subtle;
    if (!s) throw new ReaderError('noWebCrypto');
    return s;
  }

  /**
   * PBKDF2-HMAC-SHA256 to a non-extractable AES-GCM key. The password is NFC-normalised first,
   * as Parley does, so the same visible password gives the same key however it was typed.
   */
  async function deriveKey(password, header) {
    const bytes = new TextEncoder().encode(String(password).normalize('NFC'));
    const s = subtle();
    const material = await s.importKey('raw', bytes, 'PBKDF2', false, ['deriveKey']);
    bytes.fill(0);
    return s.deriveKey(
      { name: 'PBKDF2', hash: 'SHA-256', salt: header.salt, iterations: header.iterations },
      material,
      { name: 'AES-GCM', length: 256 },
      false,
      ['decrypt'],
    );
  }

  /** `parley.conversation|1|<ID>|PBKDF2-HMAC-SHA256|<iterations>|<salt base64>|AES-256-GCM` */
  function additionalData(header) {
    const parts = [FORMAT, String(VERSION), header.id.toUpperCase(), KDF_NAME,
      String(header.iterations), bytesToBase64(header.salt), CIPHER_NAME];
    return new TextEncoder().encode(parts.join('|'));
  }

  /** Decrypts with a derived key. A wrong password and a tampered file both fail authentication. */
  async function open(header, key) {
    const box = header.payload;
    if (box.length < NONCE_BYTES + TAG_BYTES) throw new ReaderError('corrupt', 'encrypted payload is malformed');
    let plain;
    try {
      plain = await subtle().decrypt(
        { name: 'AES-GCM', iv: box.subarray(0, NONCE_BYTES), additionalData: additionalData(header), tagLength: 128 },
        key,
        box.subarray(NONCE_BYTES),
      );
    } catch (_) {
      throw new ReaderError('wrongPassword');
    }
    let conversation;
    try {
      conversation = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plain));
    } catch (_) {
      throw new ReaderError('corrupt', 'invalid decrypted payload');
    } finally {
      new Uint8Array(plain).fill(0);
    }
    checkConversation(conversation);
    if (conversation.id.toUpperCase() !== header.id) {
      throw new ReaderError('corrupt', 'conversation id does not match header');
    }
    return conversation;
  }

  async function decrypt(header, password) {
    return open(header, await deriveKey(password, header));
  }

  return { FORMAT, VERSION, MAX_ITERATIONS, ReaderError, parseFile, decrypt, base64ToBytes, bytesToBase64 };
})();
if (typeof globalThis !== 'undefined') globalThis.ParleyCore = ParleyCore;
