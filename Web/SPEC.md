# Parley Web — phase 1 specification

Parley Web is a chat client in one self-contained HTML file, built from `Web/src/` the way the
Reader is built from `Reader/src/`. It talks to the OpenAI-compatible servers the user adds, and to
nothing else. Conversations are stored in the browser (IndexedDB) in Parley's own conversation
format, so a file exported from Parley Web opens in Parley for Mac, and the other way round.

The Reader stays what it is: a viewer with no network at all. Parley Web is a separate page.

## Scope of phase 1

In: servers (OpenAI-compatible base URL, optional API key), model list and choice; streaming
chat with reasoning (`reasoning_content`, `reasoning`, `<think>` tags); stop; edit and resend,
regenerate, roll back, fork, copy; image and text attachments (pick, drop, paste); Markdown;
conversation settings (system prompt, temperature, max tokens, reasoning effort incl. None);
password-encrypted conversations (Parley's format) with lock and unlock; context usage and limit
(manual value, value learned from an overflow error, value a server lists); context compaction
(automatic at a threshold, Compact Now, Restore Full History); import and export of Parley
conversation files; skins, light/dark, English and Simplified Chinese.

Out (later phases): tools (native and ReAct), built-in tools, MCP, skills, folder storage.

## Files

| File | What | Global |
|---|---|---|
| `Reader/src/core.js` | shared: parse/decrypt (exists) + encrypt (new) | `ParleyCore` |
| `Reader/src/markdown.js` | shared, unchanged | `ParleyMarkdown` |
| `Web/src/chat.js` | requests, SSE, stream accumulation, errors, model list, speed | `ParleyChat` |
| `Web/src/context.js` | token estimate, usage, limit, compaction | `ParleyContext` |
| `Web/src/store.js` | IndexedDB storage, export/import | `ParleyStore` |
| `Web/src/web.html` | the page (a fork of `Reader/src/reader.html`) | — |
| `tools/build_web.sh` | builds `Web/ParleyWeb.html` | — |
| `tools/test_web.sh` | node tests + Swift cross-check | — |

Every module is an IIFE assigning one global, with no DOM use (except `store.js`, which uses
IndexedDB and is tested with a small in-memory stand-in), runnable in Node 18+ for tests
(`globalThis.crypto`, `fetch`, `TextDecoder` exist there). No dependencies, no build step beyond
inlining, no `</script` or `<!--` in any module (the build refuses them).

## Data shapes (must decode in Swift: `Sources/ParleyCore/Models.swift`)

Conversation, Message, Attachment, ConversationSettings, TokenUsage, GenerationStats,
ConversationCompaction exactly as Swift encodes them (Codable, nil fields omitted):

- ids: uppercase UUID strings (`crypto.randomUUID().toUpperCase()`).
- dates: ISO 8601 **without fractional seconds**, `2026-11-23T10:15:30Z` (Swift `.iso8601`
  rejects fractions). Helper `ParleyContext.isoNow()` / `isoDate(date)`.
- Message required keys: `id, role, content, attachments, createdAt, isComplete`.
- Attachment: `{id, kind: "image"|"text", filename, mimeType, data?: base64, text?}`.
- ConversationSettings required: `model, systemPrompt`; optional `providerID, temperature,
  maxTokens, reasoningEffort ("low"|"medium"|"high"), disablesThinking (true only)`.
- Errors stored in `message.error` are the same fixed English strings the Mac app stores
  (`SystemErrorText`/`ChatClient` messages, e.g. "HTTP 401: ..."), so either app presents them.

## `ParleyChat` (port of ChatClient.swift, Streaming.swift, GenerationStats.swift)

- `chatURL(baseURL)`, `modelsURL(baseURL)`: same rules as `ChatClient` (a base URL with or
  without `/v1`, trailing slashes).
- `buildRequestBody(messages, options)`: the no-tools path of `ChatClient.buildRequestBody`,
  byte-for-byte in key set and values (system text = systemPrompt + historySummary; per-role
  rules; text attachments as `<file name="…">` blocks with `"` → `&quot;`; images as content
  parts with data URLs; blank assistant replies skipped; reasoning never sent; `stream: true`;
  `stream_options.include_usage` unless `options.omitStreamOptions`; temperature, max_tokens,
  reasoning_effort; "None" thinking-off fields per `options.serverKind` as
  `thinkingOffFields(for:)`). Options: `{model, systemPrompt, temperature, maxTokens,
  reasoningEffort, disablesThinking, omitsThinkingOff, serverKind, historySummary,
  omitStreamOptions}`.
- `SSEParser`: `feed(text) → payloads[]`, `finish() → payloads[]` (port of the line parser).
- `parseChunk(payload) → delta` `{content, reasoning, usage, finishReason, timings,
  promptProgress, error}` (port of ChatDelta parsing, incl. error objects inside the stream).
- `StreamAccumulator`: `apply(delta, now)`, `finish(now)`, fields `content, reasoning, usage,
  finishReason, reasoningStartedAt, reasoningEndedAt, isReasoning` (port incl. `<think>` splitting
  and reclassification).
- `GenerationMeter`: tokens/s and time to first token as the app computes them.
- `async *streamChat({baseURL, apiKey, messages, options, signal, fetchImpl})`: POSTs with
  `Authorization: Bearer` when a key is set, `Accept: text/event-stream`; reads
  `response.body` as a stream; yields deltas; on a non-2xx answer throws `ChatError` whose
  `.message` is the English text the app would store (HTTP status + server message,
  summarised HTML pages); retries once without `stream_options` when the server rejects it,
  and once without the thinking-off fields when it rejects them (yielding
  `{thinkingOffRejected: true}`), as `streamChat` does. A network failure (CORS, mixed content,
  server down) throws `ChatError` with `kind: 'network'` and the English text
  "Could not connect to the server." plus `.hint` naming CORS and mixed content.
- `async listModels({baseURL, apiKey, signal, fetchImpl})` → `[{id, contextLength?, maxContextLength?}]`
  from `/v1/models`: `contextLength` is what is loaded (as ModelInfo's loadedContextLength),
  `maxContextLength` the most the model supports; the page maps them to `ParleyContext.limit`'s
  `info`.
- `contextLengthFromError(text)`: port of `ContextBudget.contextLength(fromError:)`.

## `ParleyContext` (port of ContextBudget.swift and Compaction.swift)

- `estimateTokens(text)`, `estimateMessage(message)`, `usage(messages, systemPrompt,
  {inFlightID, liveCompletionTokens, liveIsEstimated, anchorsFrom})` → `{tokens, isEstimated}`.
- `limit({info, manual, learned})` → `{tokens, source}` or null (same precedence).
- Compaction: `block(summary)`, `isDue(usage, limit, percent)`, `boundary(messages, current,
  limitTokens, before)`, `requestMessages(previousSummary, messages)` (with role alternation),
  `chunks(messages, budget)`, `effectiveHistory(conversation)` → `{messages, summaryBlock,
  anchorsFrom, coveredCount}`, `systemText(effective, prompt)`, `truncate(conversation, index)`
  and `forked(conversation, index, newID)` with the same compaction rules (drop when the
  covered message goes, re-point the stale mark), constants (80, 30…95, 2048, 0.25),
  `INSTRUCTION` identical to `Compaction.instruction`.
- `isoNow()`, `isoDate(d)`, `newID()`.

## `ParleyStore`

- `open(indexedDB)`; stores `conversations` (`{id, title, updatedAt, encrypted, messageCount,
  body}` where body is the Conversation object, or the encrypted file text), `providers`,
  `settings`.
- `list()`, `get(id)`, `put(conversation, {key})` (encrypts with an unlocked key when given),
  `remove(id)`, `providers.list/put/remove`, `settings.get/set`.
- API keys: stored only when the user chooses "Remember in this browser", in the `providers`
  store; otherwise held in memory for the session.
- `exportFile(conversation, key?)` → text in Parley's file format; `importFile(text)` →
  `{kind:'plain', conversation}` or `{kind:'encrypted', header}` (then `ParleyCore.decrypt`).

## Encryption (`ParleyCore`, shared with the Reader)

Add `newKey(password, iterations = 600000)` → `{key, salt, iterations}` (PBKDF2-HMAC-SHA256 to
AES-256-GCM, non-extractable) and `encryptFile(conversation, keyInfo)` → file text with the
same header, AAD, nonce/tag layout and payload (JSON of the Conversation) as
`ConversationFile.encode`. Also `keyFromHeader(header, password)` for reuse after unlock. The
Reader keeps using only parse/decrypt; its page audit (no network APIs) must still pass.

## Decisions

- **Shared origin.** `https://yxengram.github.io` is shared by every GitHub Pages site of that
  account, and browser storage is per origin, not per path. So: API keys are kept for the
  session only by default; "Remember in this browser" says that any page on the same address
  could read it. The privacy note recommends encrypting conversations (ciphertext at rest) or
  using the downloaded file. The IndexedDB database is named `parley-web`.
- **Storage may be missing or temporary** (a local file in some browsers, private windows,
  Safari eviction). At start the page writes and reads a test record; if that fails it runs
  with memory only and says so in a banner, and export/import is the way to keep work. It asks
  for `navigator.storage.persist()` and shows whether it was granted.
- **Server kind** is chosen per server in Settings (Automatic, LM Studio, llama.cpp, vLLM,
  Ollama, Strata, OpenAI-compatible); Automatic sends the hosted "None" shape and relies on the
  rejection retry, as the app does before its probe answers. No probing in phase 1 except
  `/v1/models`.
- **Two tabs** on the same conversation: a `BroadcastChannel('parley-web')` message after each
  save makes the other tab reload it when it is not streaming; otherwise the last write wins.
- **Local Network Access.** Chrome asks the user before a page on the internet reaches this device
  (`loopback-network`) or the local network (`local-network`); refused, the fetch fails like any
  network error. `ParleyChat.addressSpace(baseURL)` → `'loopback' | 'local' | 'public' | null`;
  the page compares it with its own address and, after a network failure, shows a hint for a
  denied or unanswered permission instead of the general one. A local file needs no permission.
- **Mock server for browser tests:** `MOCK_CORS=1 tools/mock_server.py …` answers preflights and
  adds `Access-Control-Allow-Origin: *` (and the allowed headers) to every response.

## Port fidelity: Swift oracle vectors

`Tests/ParleyCoreTests/WebOracleTests.swift` writes JSON vectors from the app's own code into
`Web/tests/vectors/` (run with `PARLEY_WEB_VECTORS=Web/tests/vectors swift test --filter
writeWebVectors`; committed). The node tests load them and must match exactly:
`sse.json` (lines → payloads), `chunks.json` (payload → delta or English error),
`accumulator.json` (deltas → content/reasoning), `requests.json` (history × options → body,
compared as parsed JSON, deep-equal), `usage.json` (estimates, message estimates, usage with
anchors, limit precedence), `compaction.json` (instruction, block, constants, boundary cases,
requestMessages, chunks, effectiveHistory after truncate, forks, isDue), `errors.json`
(context length from error text). Messages in the vectors are encoded as the app writes them
(ISO dates, base64 data). When a JS module disagrees with a vector, the JS is wrong.

## Cross-checks

- `tools/test_web.sh`: node tests for each module; node writes fixtures (plain and encrypted
  files, request bodies for a fixed history) into a temp folder; `swift test --filter
  readWebFixtures` (`Tests/ParleyCoreTests/WebFixtureTests.swift`, skipped unless
  `PARLEY_WEB_FIXTURES` is set) decodes them with Parley's own code and compares request bodies
  with `ChatClient.buildRequestBody` for the same history and options.
- The page: like the Reader's audit, but network is allowed only through `ParleyChat`
  (`fetch` appears only in `chat.js`); CSP `connect-src http: https:` (the user's servers can be anywhere),
  `object-src`, `frame-src`, `worker-src` `'none'`, nothing else remote.

## Page

A fork of the Reader page with: a New Chat button and the stored list in the sidebar (rename,
export, delete, encrypt, lock), the composer (Enter sends, Shift-Enter newline, attach, drop,
paste, Stop), the model picker in the header, hover actions on messages, the context strip with
a popover (usage, limit with "Your value", compaction card), conversation settings, and a
Settings dialog (Servers: name, base URL, API key, remember key, default model, Test; General:
skin, appearance, compaction). Same look, same i18n tables extended.

Deployed beside the Reader: `https://yxengram.github.io/Parley/web/`, and `ParleyWeb.html` in each
release for use as a local file (which avoids mixed-content blocking of `http://` servers in
Chrome and Firefox).
