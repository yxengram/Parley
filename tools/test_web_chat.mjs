// Tests Web/src/chat.js (ParleyChat) against the Swift oracle vectors (Web/tests/vectors) and
// against tools/mock_server.py started on a free 127.0.0.1 port.
//   node tools/test_web_chat.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(join(root, 'Web/src/chat.js'), 'utf8');
for (const bad of ['</script', '<!' + '--']) assert.ok(!source.includes(bad), `chat.js must not contain ${bad}`);
const C = vm.runInThisContext(`${source}\n;ParleyChat`, { filename: 'Web/src/chat.js' });
const vec = (name) => JSON.parse(readFileSync(join(root, 'Web/tests/vectors', name), 'utf8'));

let passed = 0;
let failed = 0;
const pending = [];
async function test(name, fn) {
  try { await fn(); passed++; } catch (e) { failed++; console.log(`FAIL ${name}\n     ${e && e.stack ? e.stack.split('\n').slice(0, 4).join('\n     ') : e}`); }
}

// Small seeded generator so a failing chunking can be repeated.
let seed = 12345;
const rand = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
function randomChunks(text, n) {
  const chunks = [];
  let i = 0;
  while (i < text.length) {
    const len = 1 + Math.floor(rand() * n);
    chunks.push(text.slice(i, i + len));
    i += len;
  }
  return chunks;
}

// ---- vectors -----------------------------------------------------------------------------------

const sse = vec('sse.json');
sse.forEach((c, i) => {
  pending.push(test(`sse #${i} lines (feedLine)`, () => {
    const p = new C.SSEParser();
    const out = [];
    for (const line of c.lines) out.push(...p.feedLine(line));
    out.push(...p.finish());
    assert.deepEqual(out, c.payloads);
  }));
  pending.push(test(`sse #${i} text in random chunks (feed)`, () => {
    const text = c.lines.map((l) => l + '\n').join('');
    for (const size of [1, 2, 3, 7, 1000]) {
      for (let round = 0; round < 6; round++) {
        const p = new C.SSEParser();
        const out = [];
        for (const chunk of randomChunks(text, size)) out.push(...p.feed(chunk));
        out.push(...p.finish());
        assert.deepEqual(out, c.payloads, `chunk size ${size}`);
      }
    }
    // CRLF line ends, split anywhere (including between \r and \n).
    const crlf = c.lines.map((l) => l + '\r\n').join('');
    for (let round = 0; round < 6; round++) {
      const p = new C.SSEParser();
      const out = [];
      for (const chunk of randomChunks(crlf, 3)) out.push(...p.feed(chunk));
      out.push(...p.finish());
      assert.deepEqual(out, c.payloads, 'CRLF');
    }
  }));
});

for (const [i, c] of vec('chunks.json').entries()) {
  pending.push(test(`chunk #${i}`, () => {
    if (c.error !== undefined) {
      assert.throws(() => C.parseChunk(c.payload), (e) => e instanceof C.ChatError && e.message === c.error && e.kind === 'api');
    } else {
      const got = C.parseChunk(c.payload);
      assert.deepEqual(got, c.delta);
    }
  }));
}

for (const [i, c] of vec('accumulator.json').entries()) {
  pending.push(test(`accumulator #${i}`, () => {
    const acc = new C.StreamAccumulator();
    c.deltas.forEach((d, k) => acc.apply(d, k * 1000));
    acc.finish(c.deltas.length * 1000);
    assert.equal(acc.content, c.content);
    assert.equal(acc.reasoning, c.reasoning);
    assert.equal(acc.isReasoning, false);
  }));
}

for (const [i, c] of vec('requests.json').entries()) {
  pending.push(test(`request #${i} ${c.history}/${c.variant}`, () => {
    const o = c.options;
    const options = { ...o };
    delete options.includeUsage;
    const body = C.buildRequestBody(c.messages, options, o.includeUsage === true);
    assert.deepEqual(JSON.parse(JSON.stringify(body)), c.body);
  }));
}

for (const [i, c] of vec('errors.json').entries()) {
  pending.push(test(`context length from error #${i}`, () => {
    assert.equal(C.contextLengthFromError(c.text), c.contextLength);
  }));
}

await Promise.all(pending);

// ---- pure behaviour not in the vectors ---------------------------------------------------------

await test('URL rules', () => {
  assert.equal(C.chatURL('http://h:1/v1'), 'http://h:1/v1/chat/completions');
  assert.equal(C.chatURL('  http://h:1/v1///  '), 'http://h:1/v1/chat/completions');
  assert.equal(C.modelsURL('https://api.example.com/v1/'), 'https://api.example.com/v1/models');
  assert.equal(C.chatURL('http://h:1'), 'http://h:1/chat/completions');
  for (const bad of ['', 'ftp://h/v1', 'nonsense', 'http://']) {
    assert.throws(() => C.chatURL(bad), (e) => e instanceof C.ChatError && e.message === `Invalid API base URL: ${bad}`);
  }
});

await test('address spaces (Local Network Access)', () => {
  const cases = {
    'http://127.0.0.1:1234': 'loopback', 'http://localhost:1234/v1': 'loopback', 'http://LOCALHOST': 'loopback',
    'http://app.localhost:8080': 'loopback', 'http://[::1]:1234': 'loopback', 'http://127.5.6.7': 'loopback',
    'http://[::ffff:127.0.0.1]:1234': 'loopback', 'http://0.0.0.0:1234/v1': 'loopback',
    'http://192.168.1.20:1234': 'local', 'http://10.0.0.5': 'local', 'http://172.16.0.1': 'local',
    'http://172.31.255.255': 'local', 'http://169.254.1.1': 'local', 'http://100.64.0.1': 'local',
    'http://100.127.1.1': 'local', 'http://[fd00::1]': 'local', 'http://[fe80::1]': 'local',
    'http://studio.local:1234': 'local',
    'http://172.32.0.1': 'public', 'http://100.128.0.1': 'public', 'https://8.8.8.8': 'public',
    'http://[2001:db8::1]': 'public',
    'https://api.example.com/v1': null, 'http://mybox:1234': null, 'not a url': null, '': null,
  };
  for (const [url, want] of Object.entries(cases)) assert.equal(C.addressSpace(url), want, url);
});

await test('thinking-off fields per server kind', () => {
  assert.deepEqual(C.thinkingOffFields('llamaCpp'), { chat_template_kwargs: { enable_thinking: false } });
  assert.deepEqual(C.thinkingOffFields('vLLM'), { chat_template_kwargs: { enable_thinking: false } });
  for (const k of ['strata', 'ollama', 'lmStudio', 'hosted', null, undefined]) assert.deepEqual(C.thinkingOffFields(k), { reasoning_effort: 'none' });
  assert.deepEqual(C.sentThinkingOffFields({ disablesThinking: true, serverKind: 'vLLM' }), ['chat_template_kwargs']);
  assert.deepEqual(C.sentThinkingOffFields({ disablesThinking: true, omitsThinkingOff: true }), []);
  assert.deepEqual(C.sentThinkingOffFields({}), []);
});

await test('generation meter', () => {
  const m = new C.GenerationMeter(1000);
  m.record({ content: '' }, 1100);
  assert.equal(m.finalStats(), null);
  m.record({ content: 'a' }, 1500);
  m.record({ reasoning: 'b' }, 2000);
  m.record({ content: 'c' }, 3500);
  m.record({ finishReason: 'stop' }, 3600);
  assert.equal(m.timeToFirstToken, 0.5);
  const s = m.finalStats();
  assert.deepEqual(s, { tokensPerSecond: 1, completionTokens: 3, timeToFirstToken: 0.5, generationDuration: 2, isEstimated: true, finishReason: 'stop' });
  // Server counts win; llama.cpp timings win over both.
  m.record({ usage: { completionTokens: 9, cachedPromptTokens: 4 } }, 3700);
  assert.equal(m.generatedTokens, 9);
  assert.equal(m.isEstimated, false);
  assert.equal(m.finalStats().cachedPromptTokens, 4);
  m.record({ timings: { predictedTokens: 40, predictedMilliseconds: 800, predictedPerSecond: 50, promptTokens: 12, promptMilliseconds: 30, cachedTokens: 7 } }, 3800);
  const t = m.finalStats();
  assert.equal(t.tokensPerSecond, 50);
  assert.equal(t.completionTokens, 40);
  assert.equal(t.generationDuration, 0.8);
  assert.equal(t.promptTokensRead, 12);
  assert.equal(t.promptTokensPerSecond, 400);
  assert.equal(t.cachedPromptTokens, 7);
  // Hidden reasoning (counted by the server, never streamed) is left out of the rate.
  const h = new C.GenerationMeter(0);
  h.record({ content: 'a' }, 1000);
  h.record({ content: 'b' }, 2000);
  h.record({ usage: { completionTokens: 12, reasoningTokens: 10 } }, 2100);
  assert.equal(h.tokensPerSecond, 1);
});

await test('error body texts', async () => {
  const mk = (status, headers, body) => ({
    ok: false, status, type: 'basic',
    headers: new Headers(headers),
    body: new Response(body).body,
  });
  const run = async (resp, base = 'http://x/v1') => {
    try {
      for await (const d of C.streamChat({ baseURL: base, messages: [], options: { model: 'm' }, fetchImpl: async () => resp })) void d;
      return null;
    } catch (e) { return e; }
  };
  let e = await run(mk(401, { 'content-type': 'application/json' }, '{"error":{"message":"bad key"}}'));
  assert.equal(e.message, 'HTTP 401: {"error":{"message":"bad key"}}');
  e = await run(mk(502, { 'content-type': 'text/html' }, '<html><head><title>502 Bad Gateway</title></head><body>x</body></html>'));
  assert.equal(e.message, 'HTTP 502: 502 Bad Gateway');
  e = await run(mk(500, {}, '<!DOCTYPE html><html><body><h1>Oops &amp; sorry</h1></body></html>'));
  assert.equal(e.message, 'HTTP 500: Oops & sorry');
  e = await run(mk(530, { server: 'cloudflare', 'cf-ray': '8f1a2b3c4d5e6f70-SYD', 'content-type': 'text/plain' }, 'error code: 1033'));
  assert.equal(e.message, 'HTTP 530: Cloudflare error 1033 · Ray ID 8f1a2b3c4d5e6f70-SYD');
  e = await run(mk(404, {}, 'Not found'));
  assert.equal(e.kind, 'http');
  e = await run(mk(404, {}, 'Not found'), 'http://x');
  assert.equal(e.kind, 'api');
  assert.equal(e.message, `API error: Endpoint not found (HTTP 404): Not found ${C.MISSING_VERSION_PATH_HINT}`);
  e = await run(mk(400, {}, 'x'.repeat(5000)));
  assert.equal(e.message.length, 'HTTP 400: '.length + 2000);
  // A network failure.
  try {
    for await (const d of C.streamChat({ baseURL: 'http://x/v1', messages: [], options: { model: 'm' }, fetchImpl: async () => { throw new TypeError('fetch failed'); } })) void d;
    assert.fail('no throw');
  } catch (err) {
    assert.equal(err.kind, 'network');
    assert.equal(err.message, 'Could not connect to the server.');
    assert.ok(/CORS/.test(err.hint) && /mixed content/.test(err.hint));
  }
});

await test('stream cut without finish reason is an interruption', async () => {
  const body = new Response('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n').body;
  const resp = { status: 200, type: 'basic', headers: new Headers({ 'content-type': 'text/event-stream' }), body };
  try {
    for await (const d of C.streamChat({ baseURL: 'http://x/v1', messages: [], options: { model: 'm' }, fetchImpl: async () => resp })) void d;
    assert.fail('no throw');
  } catch (e) {
    assert.equal(e.message, 'API error: The connection closed before the reply finished.');
  }
});

// ---- mock server -------------------------------------------------------------------------------

function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
    s.on('error', reject);
  });
}

async function startMock(flavor, env = {}) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const port = await freePort();
    const child = spawn('python3', ['-I', '-u', join(root, 'tools/mock_server.py'), String(port), ...(flavor ? [flavor] : [])], {
      env: { ...process.env, ...env }, stdio: 'ignore',
    });
    let exited = false;
    child.on('exit', () => { exited = true; });
    const base = `http://127.0.0.1:${port}/v1`;
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline && !exited) {
      try { if ((await fetch(`${base}/models`)).ok) return { base, origin: `http://127.0.0.1:${port}`, stop: () => child.kill() }; } catch (e) { /* not up yet */ }
      await new Promise((r) => setTimeout(r, 50));
    }
    child.kill();
  }
  throw new Error('mock server did not start');
}

async function collect(args) {
  const deltas = [];
  for await (const d of C.streamChat(args)) deltas.push(d);
  return deltas;
}
function fold(deltas) {
  const acc = new C.StreamAccumulator();
  const meter = new C.GenerationMeter(Date.now());
  for (const d of deltas) { acc.apply(d); meter.record(d); }
  acc.finish();
  return { acc, meter };
}
const user = (text) => ({ id: 'A', role: 'user', content: text, attachments: [], createdAt: '2027-01-01T00:00:00Z', isComplete: true });
const lastRequest = async (m) => (await fetch(`${m.origin}/mock/last-request`)).json();
const counters = async (m) => (await fetch(`${m.origin}/mock/requests`)).json();

// ---- review fixes (stubbed fetch, no server) ------------------------------------------------------

const sseResponse = (chunks, status = 200) => {
  const enc = new TextEncoder();
  let i = 0;
  return new Response(new ReadableStream({
    pull(c) { if (i < chunks.length) c.enqueue(enc.encode(chunks[i++])); else c.close(); },
  }), { status, headers: { 'content-type': 'text/event-stream' } });
};
const stubChat = (chunks, extra = {}) => ({ baseURL: 'http://x/v1', messages: [user('Q')], options: { model: 'm' }, fetchImpl: async () => sseResponse(chunks), ...extra });
const content = (t) => `data: ${JSON.stringify({ choices: [{ delta: { content: t } }] })}\n\n`;
const stop = 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n';
const errorPayload = 'data: {"error":{"message":"boom"}}\n\n';

await test('deltas before an error payload in the same read are delivered', async () => {
  const got = [];
  await assert.rejects(async () => { for await (const d of C.streamChat(stubChat([content('hi') + errorPayload + 'data: [DONE]\n\n']))) got.push(d); },
    (e) => e.kind === 'api' && e.message === 'API error: boom');
  assert.equal(got.length, 1);
  assert.equal(got[0].content, 'hi');
});

await test('nothing after [DONE] in the same read is parsed', async () => {
  const { acc } = fold(await collect(stubChat([content('a') + 'data: [DONE]\n\n' + errorPayload + content('late')])));
  assert.equal(acc.content, 'a');
});

await test('request construction failures are not reported as network errors', async () => {
  let called = 0;
  const fetchImpl = async () => { called++; return sseResponse([content('x') + stop]); };
  await assert.rejects(collect(stubChat([], { apiKey: 'sk-“abc”', fetchImpl })),
    (e) => e.kind === 'api' && /API key contains characters/.test(e.message));
  await assert.rejects(C.listModels({ baseURL: 'http://x/v1', apiKey: 'k’', fetchImpl }), (e) => e.kind === 'api');
  await assert.rejects(collect(stubChat([], { baseURL: 'http://user:pw@host/v1', fetchImpl })), (e) => e.kind === 'invalidBaseURL');
  await assert.rejects(C.listModels({ baseURL: 'http://user@host/v1', fetchImpl }), (e) => e.kind === 'invalidBaseURL');
  assert.equal(called, 0);
  // Latin-1 characters are fine in a header.
  await collect(stubChat([content('x')], { apiKey: 'café', fetchImpl }));
  assert.equal(called, 1);
});

await test('U+0085 counts as whitespace like Swift (system prompt, blank messages)', () => {
  const body = C.buildRequestBody([user('hi')], { model: 'm', systemPrompt: '\u0085\u0085' }, false);
  assert.ok(!body.messages.some((m) => m.role === 'system'), JSON.stringify(body.messages));
  const padded = C.buildRequestBody([user('hi')], { model: 'm', systemPrompt: '\u0085be brief\u0085' }, false);
  assert.equal(padded.messages[0].role, 'system'); // a real prompt is kept as written
});

await test('a non-transport failure mid-stream is not disguised as a lost connection', async () => {
  const bug = async () => ({
    status: 200, type: 'basic', headers: new Headers({ 'content-type': 'text/event-stream' }),
    body: { getReader: () => ({ read: async () => { throw new RangeError('our bug'); }, cancel: async () => {} }) },
  });
  await assert.rejects(collect(stubChat([], { fetchImpl: bug })), (e) => e instanceof RangeError);
  const lost = async () => ({
    status: 200, type: 'basic', headers: new Headers({ 'content-type': 'text/event-stream' }),
    body: { getReader: () => ({ read: async () => { throw new TypeError('terminated'); }, cancel: async () => {} }) },
  });
  await assert.rejects(collect(stubChat([], { fetchImpl: lost })), (e) => e.kind === 'api' && /connection was lost/.test(e.message));
});

await test('truncation counts Characters (graphemes), not code points', async () => {
  const flags = '\u{1F1E9}\u{1F1EA}'.repeat(1800); // 1800 flags = 3600 UTF-16 units, 1800 Characters
  const e = await C.listModels({ baseURL: 'http://x/v1', fetchImpl: async () => new Response(flags, { status: 500, headers: { 'content-type': 'text/plain' } }) }).catch((x) => x);
  if (typeof Intl.Segmenter === 'function') assert.ok(e.message.endsWith(flags), 'kept whole');
  const long = await C.listModels({ baseURL: 'http://x/v1', fetchImpl: async () => new Response('a'.repeat(5000), { status: 500 }) }).catch((x) => x);
  assert.ok(long.message.length < 2100);
});

await test('opaqueredirect on listModels is a redirect error', async () => {
  await assert.rejects(C.listModels({ baseURL: 'http://x/v1', fetchImpl: async () => ({ type: 'opaqueredirect', status: 0 }) }), (e) => e.kind === 'redirect');
});

await test('both retries: streamOptionsRejected then thinkingOffRejected', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    const b = JSON.parse(init.body);
    seen.push(b);
    if (b.stream_options) return new Response('{"error":{"message":"Unknown parameter: stream_options"}}', { status: 400, headers: { 'content-type': 'application/json' } });
    if (b.reasoning_effort === 'none') return new Response('{"error":{"message":"Unsupported value: \'none\' is not supported with the \'reasoning_effort\' parameter."}}', { status: 400, headers: { 'content-type': 'application/json' } });
    return sseResponse([content('ok') + stop]);
  };
  const deltas = await collect({ baseURL: 'http://x/v1', messages: [user('Q')], options: { model: 'm', disablesThinking: true, serverKind: 'hosted' }, fetchImpl });
  assert.deepEqual(deltas[0], { streamOptionsRejected: true });
  assert.deepEqual(deltas[1], { thinkingOffRejected: true });
  assert.equal(fold(deltas).acc.content, 'ok');
  assert.equal(seen.length, 3);
});

await test('leaving the loop early cancels the body and aborts the request', async () => {
  let cancelled = false;
  let aborted = false;
  const fetchImpl = async (url, init) => {
    init.signal.addEventListener('abort', () => { aborted = true; });
    const enc = new TextEncoder();
    return new Response(new ReadableStream({
      pull(c) { c.enqueue(enc.encode(content('x'))); },
      cancel() { cancelled = true; },
    }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
  };
  for await (const d of C.streamChat({ baseURL: 'http://x/v1', messages: [user('Q')], options: { model: 'm' }, fetchImpl })) { void d; break; }
  assert.ok(cancelled, 'body cancelled');
  assert.ok(aborted, 'request aborted');
});

const mock = await startMock(null, { MOCK_CORS: '1' });
const strict = await startMock('openai-strict');
const llama = await startMock('llamacpp');
const keyed = await startMock('strata-engine');
try {
  await test('MOCK_CORS: preflight and Allow-Origin on every response', async () => {
    const pre = await fetch(`${mock.base}/chat/completions`, { method: 'OPTIONS' });
    assert.equal(pre.status, 204);
    assert.equal(pre.headers.get('access-control-allow-origin'), '*');
    assert.equal(pre.headers.get('access-control-allow-methods'), 'GET, POST, OPTIONS');
    assert.equal(pre.headers.get('access-control-allow-headers'), 'Authorization, Content-Type');
    assert.equal(pre.headers.get('access-control-max-age'), '600');
    const err = await fetch(`${mock.base}/chat/completions`, { method: 'POST', body: JSON.stringify({ model: 'mock-error' }) });
    assert.equal(err.status, 400);
    assert.equal(err.headers.get('access-control-allow-origin'), '*');
    const stream = await fetch(`${mock.base}/chat/completions`, { method: 'POST', body: JSON.stringify({ model: 'mock-plain', stream: true }) });
    assert.equal(stream.headers.get('access-control-allow-origin'), '*');
    await stream.text();
    // Without MOCK_CORS nothing changes: no CORS header, OPTIONS unsupported.
    const plain = await fetch(`${strict.base}/models`);
    assert.equal(plain.headers.get('access-control-allow-origin'), null);
    assert.equal((await fetch(`${strict.base}/models`, { method: 'OPTIONS' })).status, 501);
  });

  await test('streamChat: plain', async () => {
    const deltas = await collect({ baseURL: mock.base, messages: [user('Hello there')], options: { model: 'mock-plain' } });
    const { acc, meter } = fold(deltas);
    assert.ok(acc.content.includes('Hello there'), acc.content);
    assert.equal(acc.reasoning, '');
    assert.equal(acc.finishReason, 'stop');
    assert.ok(meter.finalStats().completionTokens > 0);
    const req = await lastRequest(mock);
    assert.equal(req.model, 'mock-plain');
    assert.equal(req.stream, true);
    assert.deepEqual(req.stream_options, { include_usage: true });
  });

  await test('streamChat: reasoning (reasoning_content, reasoning, think tags, orphan)', async () => {
    for (const model of ['mock-reasoning-content', 'mock-reasoning', 'mock-think-tags', 'mock-orphan-think']) {
      const { acc } = fold(await collect({ baseURL: mock.base, messages: [user('Q')], options: { model } }));
      assert.ok(acc.reasoning.length > 0, `${model} reasoning`);
      assert.ok(acc.content.length > 0, `${model} content`);
      assert.ok(!/<\/?think/.test(acc.content + acc.reasoning), `${model} leaked a tag`);
      assert.equal(acc.isReasoning, false);
      assert.ok(acc.reasoningStartedAt !== null && acc.reasoningEndedAt !== null);
    }
  });

  await test('streamChat: usage', async () => {
    const withUsage = fold(await collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-plain' } }));
    assert.ok(withUsage.acc.usage && withUsage.acc.usage.completionTokens > 0, JSON.stringify(withUsage.acc.usage));
    assert.equal(withUsage.meter.isEstimated, false);
    const without = fold(await collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-plain', omitStreamOptions: true } }));
    assert.equal(without.acc.usage, null);
    assert.equal((await lastRequest(mock)).stream_options, undefined);
    const timed = fold(await collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-timings' } }));
    assert.ok(timed.meter.timings && timed.meter.timings.predictedTokens > 0);
    assert.equal(timed.meter.finalStats().tokensPerSecond, timed.meter.timings.predictedPerSecond);
  });

  await test('streamChat: HTTP error (mock-error)', async () => {
    await assert.rejects(
      collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-error' } }),
      (e) => e instanceof C.ChatError && e.kind === 'http' && e.status === 400
        && e.message === 'HTTP 400: {"error": {"message": "mock bad request"}}',
    );
  });

  await test('streamChat: error payload inside a 200 stream', async () => {
    await assert.rejects(
      collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-stream-error' } }),
      (e) => e instanceof C.ChatError && e.kind === 'api' && e.message.startsWith('API error: '),
    );
    for (const model of ['mock-sse-error-field', 'mock-sse-error-event', 'mock-bare-error']) {
      await assert.rejects(collect({ baseURL: mock.base, messages: [user('Q')], options: { model } }),
        (e) => e instanceof C.ChatError && e.kind === 'api', model);
    }
  });

  await test('streamChat: dropped and cut streams', async () => {
    for (const model of ['mock-drop', 'mock-cut']) {
      const got = [];
      await assert.rejects(async () => { for await (const d of C.streamChat({ baseURL: mock.base, messages: [user('Q')], options: { model } })) got.push(d); },
        (e) => e instanceof C.ChatError && e.kind === 'api' && e.message.startsWith('API error: The connection closed before the reply finished'), model);
      assert.ok(got.length > 0, `${model}: partial text is delivered before the error`);
    }
  });

  await test('streamChat: stream_options rejection retries once without it', async () => {
    const before = (await counters(mock)).stream_options_rejected;
    const deltas = await collect({ baseURL: mock.base, messages: [user('Hi')], options: { model: 'mock-no-stream-options' } });
    assert.deepEqual(deltas[0], { streamOptionsRejected: true });
    assert.ok(fold(deltas).acc.content.includes('Hi'));
    assert.equal((await counters(mock)).stream_options_rejected, before + 1);
    assert.equal((await lastRequest(mock)).stream_options, undefined);
    // Remembered by the caller: omitStreamOptions sends no second request.
    const again = await collect({ baseURL: mock.base, messages: [user('Hi')], options: { model: 'mock-no-stream-options', omitStreamOptions: true } });
    assert.ok(!again.some((d) => d.streamOptionsRejected));
    assert.equal((await counters(mock)).stream_options_rejected, before + 1);
  });

  await test('streamChat: thinking-off rejection retries without the field', async () => {
    const before = (await counters(strict)).thinking_off_rejected;
    const deltas = await collect({
      baseURL: strict.base, messages: [user('Think?')],
      options: { model: 'mock-plain', disablesThinking: true, serverKind: 'hosted', reasoningEffort: 'low' },
    });
    assert.deepEqual(deltas[0], { thinkingOffRejected: true });
    assert.ok(fold(deltas).acc.content.includes('Think?'));
    assert.equal((await counters(strict)).thinking_off_rejected, before + 1);
    const req = await lastRequest(strict);
    assert.equal(req.reasoning_effort, 'low', 'the retry drops "none" and sends the chosen effort again, as the app does');
    // Without the flag the fields are never sent, and nothing is rejected.
    const plain = await collect({ baseURL: strict.base, messages: [user('x')], options: { model: 'mock-plain' } });
    assert.ok(!plain.some((d) => d.thinkingOffRejected));
  });

  await test('streamChat: when the retry fails too, the first answer is thrown', async () => {
    await assert.rejects(
      collect({ baseURL: strict.base, messages: [user('Q')], options: { model: 'mock-always-reject', disablesThinking: true, serverKind: 'hosted' } }),
      (e) => e instanceof C.ChatError && e.kind === 'http' && e.status === 400 && /Unsupported value: 'none'/.test(e.message) && /reasoning_effort/.test(e.message),
    );
  });

  await test('streamChat: a context overflow is not mistaken for a thinking refusal', async () => {
    await assert.rejects(
      collect({ baseURL: strict.base, messages: [user('Q')], options: { model: 'mock-overflow', disablesThinking: true, serverKind: 'hosted' } }),
      (e) => e.kind === 'http' && C.contextLengthFromError(e.message) === 8192,
    );
  });

  await test('streamChat: authorization header and key trimming', async () => {
    const seen = [];
    const fetchImpl = async (url, init) => { seen.push(init.headers); return fetch(url, init); };
    await collect({ baseURL: mock.base, apiKey: '  sk-test  ', messages: [user('Q')], options: { model: 'mock-plain' }, fetchImpl });
    await collect({ baseURL: mock.base, apiKey: '', messages: [user('Q')], options: { model: 'mock-plain' }, fetchImpl });
    assert.equal(seen[0].Authorization, 'Bearer sk-test');
    assert.equal(seen[0].Accept, 'text/event-stream');
    assert.equal(seen[1].Authorization, undefined);
  });

  await test('streamChat: abort via AbortSignal', async () => {
    const ctl = new AbortController();
    const got = [];
    const started = Date.now();
    await assert.rejects(async () => {
      for await (const d of C.streamChat({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-slow' }, signal: ctl.signal })) {
        got.push(d);
        if (got.length === 2) ctl.abort();
      }
    }, (e) => e.name === 'AbortError');
    assert.ok(got.length >= 2 && Date.now() - started < 4000);
    // Aborted before the first byte.
    const early = new AbortController();
    early.abort();
    await assert.rejects(collect({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-plain' }, signal: early.signal }), (e) => e.name === 'AbortError');
    // Leaving the loop early (the consumer's break) does not hang or throw.
    for await (const d of C.streamChat({ baseURL: mock.base, messages: [user('Q')], options: { model: 'mock-slow' } })) { void d; break; }
  });

  await test('streamChat: network failure (nothing listening)', async () => {
    const port = await freePort();
    await assert.rejects(
      collect({ baseURL: `http://127.0.0.1:${port}/v1`, messages: [user('Q')], options: { model: 'm' } }),
      (e) => e instanceof C.ChatError && e.kind === 'network' && e.message === 'Could not connect to the server.' && /CORS/.test(e.hint),
    );
  });

  await test('streamChat: a refused redirect is an error, never followed', async () => {
    await assert.rejects(
      collect({ baseURL: `${mock.origin}/redirect-to-9/v1`, messages: [user('Q')], options: { model: 'm' } }),
      (e) => e instanceof C.ChatError && (e.kind === 'redirect' || /^HTTP 307: Redirect to /.test(e.message) || e.kind === 'api'),
    );
  });

  await test('streamChat: Cloudflare edge page is summarised', async () => {
    await assert.rejects(
      collect({ baseURL: `${mock.origin}/cf-524/v1`, messages: [user('Q')], options: { model: 'm' } }),
      (e) => e.kind === 'http' && e.status === 524 && /^HTTP 524: Cloudflare error 524/.test(e.message) && !/<html|<style/i.test(e.message),
    );
  });

  await test('listModels', async () => {
    const models = await C.listModels({ baseURL: mock.base });
    assert.ok(models.length > 5);
    assert.ok(models.every((m) => typeof m.id === 'string'));
    assert.ok(models.some((m) => m.id === 'mock-plain'));
    assert.equal(new Set(models.map((m) => m.id)).size, models.length);
    const ids = models.map((m) => m.id);
    assert.deepEqual(ids, [...ids].sort(new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' }).compare));
  });

  await test('listModels: context length from the entry (llama.cpp meta.n_ctx)', async () => {
    const models = await C.listModels({ baseURL: llama.base });
    const raw = await (await fetch(`${llama.base}/models`)).json();
    const entry = raw.data.find((e) => e.id === 'mock-plain');
    assert.ok(entry && entry.meta && entry.meta.n_ctx > 0);
    assert.equal(models.find((m) => m.id === 'mock-plain').contextLength, entry.meta.n_ctx);
  });

  await test('listModels: shapes and errors (stubbed fetch)', async () => {
    const json = (status, obj, type = 'application/json') => async () => new Response(typeof obj === 'string' ? obj : JSON.stringify(obj), { status, headers: { 'content-type': type } });
    const ids = async (obj) => (await C.listModels({ baseURL: 'http://x/v1', fetchImpl: json(200, obj) }));
    assert.deepEqual(await ids({ data: [{ id: 'b', context_length: 4096 }, { id: 'a10' }, { id: 'a2' }, { id: 'b' }] }),
      [{ id: 'a2' }, { id: 'a10' }, { id: 'b', contextLength: 4096 }]);
    assert.deepEqual(await ids({ data: [{ id: 'u', max_context_length: 262144 }] }), [{ id: 'u', maxContextLength: 262144 }]);
    assert.deepEqual(await ids({ data: [{ id: 'l', meta: { n_ctx: 4096, n_ctx_train: 32768 } }] }), [{ id: 'l', contextLength: 4096, maxContextLength: 32768 }]);
    assert.deepEqual(await ids({ data: [{ id: 'm', max_context_length: 32768, loaded_context_length: 8192 }] }), [{ id: 'm', contextLength: 8192, maxContextLength: 32768 }]);
    assert.deepEqual(await ids({ models: [{ name: 'x' }, 'y'] }), [{ id: 'x' }, { id: 'y' }]);
    assert.deepEqual(await ids(['p', 'q']), [{ id: 'p' }, { id: 'q' }]);
    const fails = async (fetchImpl, base = 'http://x/v1') => { try { await C.listModels({ baseURL: base, fetchImpl }); } catch (e) { return e; } return null; };
    assert.equal((await fails(json(200, { error: 'Unexpected endpoint or method.' }))).message, 'API error: Unexpected endpoint or method.');
    assert.equal((await fails(json(200, { foo: 1 }))).message, "API error: The server's model list has an unexpected format.");
    assert.equal((await fails(json(200, 'not json'))).message, "API error: The server's model list is not valid JSON.");
    assert.equal((await fails(json(200, '<html><head><title>Sign in</title></head></html>', 'text/html'))).message,
      'API error: The server answered with a web page (Sign in) instead of a model list.');
    assert.equal((await fails(json(401, { error: { message: 'no' } }))).message, 'HTTP 401: {"error":{"message":"no"}}');
    assert.equal((await fails(async () => { throw new TypeError('fetch failed'); })).kind, 'network');
    const e = await fails(json(404, 'Not found'), 'http://x');
    assert.equal(e.message, `API error: Endpoint not found (HTTP 404): Not found ${C.MISSING_VERSION_PATH_HINT}`);
  });

  await test('listModels: key sent, abort', async () => {
    let auth = null;
    await C.listModels({ baseURL: mock.base, apiKey: 'k1', fetchImpl: async (u, init) => { auth = init.headers.Authorization; return fetch(u, init); } });
    assert.equal(auth, 'Bearer k1');
    const ctl = new AbortController();
    ctl.abort();
    await assert.rejects(C.listModels({ baseURL: mock.base, signal: ctl.signal }), (e) => e.name === 'AbortError');
  });

  await test('listModels: key required by the server (strata-engine, wrong key)', async () => {
    // The Strata flavors only check the key when the mock was given one; without one they answer.
    const models = await C.listModels({ baseURL: keyed.base });
    assert.ok(Array.isArray(models));
  });
} finally {
  for (const m of [mock, strict, llama, keyed]) m.stop();
}

if (failed > 0) { console.log(`${failed} failed, ${passed} passed`); process.exit(1); }
console.log(`all ${passed} passed`);
