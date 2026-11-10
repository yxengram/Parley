// Tests Reader/src/core.js against files written by Parley's own encoder.
//   node tools/test_reader_core.mjs FIXTURE_DIR
// Run through tools/test_reader.sh, which writes the fixtures first.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = process.argv[2];
if (!dir) { console.error('usage: node tools/test_reader_core.mjs FIXTURE_DIR'); process.exit(64); }

const context = vm.createContext({ crypto: globalThis.crypto, TextEncoder, TextDecoder, atob, btoa, console });
vm.runInContext(readFileSync(join(root, 'Reader/src/core.js'), 'utf8'), context);
const { parseFile, decrypt } = context.ParleyCore;
const text = name => readFileSync(join(dir, name), 'utf8');
const expected = JSON.parse(text('expected.json'));
const same = value => JSON.parse(JSON.stringify(value)); // across vm realms
const codeOf = async fn => { try { await fn(); return 'none'; } catch (e) { return e.code || String(e); } };

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log(`ok   ${name}`); } catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message}`); }
}

await test('plain file matches the conversation', () => {
  const parsed = parseFile(text('plain.json'));
  assert.equal(parsed.kind, 'plain');
  assert.deepEqual(same(parsed.conversation), expected);
});
await test('encrypted file opens with the password', async () => {
  const header = parseFile(text('encrypted.json'));
  assert.equal(header.kind, 'encrypted');
  assert.deepEqual(same(await decrypt(header, 'correct horse')), expected);
});
await test('wrong password is reported as such', async () => {
  assert.equal(await codeOf(() => decrypt(parseFile(text('encrypted.json')), 'correct hors')), 'wrongPassword');
});
await test('600k iterations, password typed decomposed (NFD) still opens', async () => {
  const started = performance.now();
  const conversation = await decrypt(parseFile(text('encrypted-600k.json')), 'café 密码');
  assert.deepEqual(same(conversation), expected);
  console.log(`     key derivation and decryption took ${Math.round(performance.now() - started)} ms`);
});
await test('a changed header fails authentication', async () => {
  assert.equal(await codeOf(() => decrypt(parseFile(text('tampered.json')), 'correct horse')), 'wrongPassword');
});
await test('old file without optional fields opens', () => {
  const c = parseFile(text('minimal.json')).conversation;
  assert.equal(c.messages.length, 1);
});
await test('other JSON is not a Parley file', async () => {
  assert.equal(await codeOf(() => parseFile(text('not-parley.json'))), 'notParley');
  assert.equal(await codeOf(() => parseFile('not json')), 'corrupt');
  assert.equal(await codeOf(() => parseFile('[]')), 'notParley');
});
await test('a newer version is refused', async () => {
  assert.equal(await codeOf(() => parseFile(text('future.json'))), 'unsupportedVersion');
});
await test('hostile headers are refused before any work', async () => {
  const good = JSON.parse(text('encrypted.json'));
  const variant = patch => JSON.stringify({ ...good, ...patch });
  assert.equal(await codeOf(() => parseFile(variant({ kdf: { ...good.kdf, iterations: 50000001 } }))), 'corrupt');
  assert.equal(await codeOf(() => parseFile(variant({ kdf: { ...good.kdf, iterations: 1.5 } }))), 'corrupt');
  assert.equal(await codeOf(() => parseFile(variant({ kdf: { ...good.kdf, name: 'scrypt' } }))), 'corrupt');
  assert.equal(await codeOf(() => parseFile(variant({ cipher: 'AES-128-CBC' }))), 'corrupt');
  assert.equal(await codeOf(() => parseFile(variant({ payload: 'not base64!' }))), 'corrupt');
  assert.equal(await codeOf(() => parseFile(variant({ id: 'nope' }))), 'corrupt');
  assert.equal(await codeOf(() => decrypt(parseFile(variant({ payload: 'AAAA' })), 'x')), 'corrupt');
});

await test('base64 over 5.6M characters: an encrypted payload and an image attachment both open (B64-BACKTRACK)', async () => {
  // The fixture's own header and key (password 'correct horse'), a conversation with a ~4.3 MB
  // PNG-typed attachment, encrypted the way Parley does it. The payload is ~7.6M base64 characters.
  const good = JSON.parse(text('encrypted.json'));
  const header = parseFile(text('encrypted.json'));
  const s = globalThis.crypto.subtle;
  const material = await s.importKey('raw', new TextEncoder().encode('correct horse'), 'PBKDF2', false, ['deriveKey']);
  const key = await s.deriveKey({ name: 'PBKDF2', hash: 'SHA-256', salt: new Uint8Array(header.salt), iterations: header.iterations },
    material, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const image = new Uint8Array(4_300_000);
  for (let i = 0; i < image.length; i++) image[i] = (i * 2654435761) >>> 24;
  const imageB64 = Buffer.from(image).toString('base64');
  assert.ok(imageB64.length > 5_600_000);
  const conversation = { ...expected, id: good.id };
  conversation.messages = [...expected.messages, { id: '6A1F7D2E-3B4C-4D5E-8F90-A1B2C3D4E5F6', role: 'user', content: 'big picture',
    attachments: [{ id: '7B2E8E3F-4C5D-4E6F-9A01-B2C3D4E5F607', kind: 'image', filename: 'big.png', mimeType: 'image/png', data: imageB64 }] }];
  const aad = new TextEncoder().encode(['parley.conversation', '1', good.id.toUpperCase(), 'PBKDF2-HMAC-SHA256',
    String(good.kdf.iterations), good.kdf.salt, 'AES-256-GCM'].join('|'));
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await s.encrypt({ name: 'AES-GCM', iv, additionalData: aad, tagLength: 128 }, key,
    new TextEncoder().encode(JSON.stringify(conversation))));
  const payload = Buffer.concat([iv, sealed]).toString('base64');
  assert.ok(payload.length > 5_600_000, `payload is ${payload.length} characters`);
  const started = performance.now();
  const parsed = parseFile(JSON.stringify({ ...good, payload }));
  const opened = await decrypt(parsed, 'correct horse');
  const att = opened.messages[opened.messages.length - 1].attachments[0];
  const bytes = context.ParleyCore.base64ToBytes(att.data);
  assert.equal(bytes.length, image.length);
  assert.equal(Buffer.compare(Buffer.from(bytes), Buffer.from(image)), 0);
  const took = performance.now() - started;
  console.log(`     ${(payload.length / 1e6).toFixed(1)}M-character payload opened in ${Math.round(took)} ms`);
  assert.ok(took < 5000, `took ${Math.round(took)} ms`);
  // Still strict: the same rules as Foundation's Data(base64Encoded:).
  const b = context.ParleyCore.base64ToBytes;
  for (const bad of ['QQ=', 'Q===', 'QQ=A', 'QUJD\n', ' QUJD', 'QU JD', 'QUJD====', '=QUJ', 'QUJ-']) assert.equal(b(bad), null, bad);
  for (const ok of ['', 'QQ==', 'QUI=', 'QUJD']) assert.notEqual(b(ok), null, ok);
  const big = 'QUJD'.repeat(2_000_000) + 'QQ==';
  const t = performance.now();
  assert.equal(b(big).length, 6_000_001);
  assert.equal(b(big.slice(0, -4) + 'QQ=!'), null);
  assert.ok(performance.now() - t < 2000);
});

console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);
