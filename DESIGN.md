# Parley: design and module contracts

Parley is a small macOS chat client for OpenAI-compatible LLM APIs, comparable to
LM Studio's chat view. It is a SwiftPM package with no Xcode project and no
third-party dependencies. `./build.sh` builds it and assembles `build/Parley.app`
(ad-hoc signed).

- Targets: `ParleyCore` (library, no SwiftUI), `Parley` (SwiftUI app), and `ParleyCoreTests` (swift-testing: `import Testing`, `@Test`, `#expect`).
- Language mode: Swift 5 for all targets. Minimum OS: macOS 14, so `@Observable` is available.
- `Sources/ParleyCore/Models.swift` holds the shared model and is already written. Do not change existing public signatures in it. You may add things to it if needed, but prefer adding them in your own files.

## Hard requirements (from the user)
1. Chat through an OpenAI-compatible API, on the internet or on a LAN (plain http allowed, LAN allowed).
2. API keys are stored in the Keychain.
3. Tools come only from MCP servers the user configures (see "MCP client"), and every call needs the user's approval unless they chose Always Allow for that tool. There are no other agent features. The app also supports image and text-file attachments.
4. Thinking/reasoning is supported: stream it, show it collapsibly, and show its duration.
5. Settings hold a default conversation directory, and each new conversation can pick its own directory. Each conversation is saved as one JSON file.
6. One click copies any user or assistant message.
7. Roll back to any past message.
8. Fork from any message.
9. **Privacy:** nothing leaves the machine except the configured API calls, calls to the MCP servers the user configured and, after the user presses Sign In and approves the hosts it names, that server's sign-in provider.
10. Per-conversation encryption. The JSON file on disk is encrypted, and decryption happens only in memory.

## Encryption decision
The user offered two options, and we use option 1. On every save, the whole conversation is re-encrypted and written atomically.
- Per-message encryption would leak message count, roles, timestamps, sizes, model, and title.
- AES-GCM over a few MB takes milliseconds, so re-encrypting everything costs nothing noticeable.
- Data stays fresh through saves, not through appending. The app saves immediately when a message completes or is sent, debounced about every 2 s while a reply streams, and on quit.

Encrypted file layout (JSON, UTF-8):
```json
{
  "format": "parley.conversation",
  "version": 1,
  "encrypted": true,
  "id": "<UUID>",
  "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 600000, "salt": "<base64 16 bytes>" },
  "cipher": "AES-256-GCM",
  "payload": "<base64 of AES.GCM.SealedBox.combined (nonce|ciphertext|tag)>"
}
```
- The payload plaintext is the JSON encoding of `Conversation`.
- AAD is the UTF-8 bytes of `"parley.conversation|1|<id uppercased UUID string>|PBKDF2-HMAC-SHA256|<iterations>|<salt base64>|AES-256-GCM"`. This binds the header to the ciphertext.
- Every save uses a fresh random nonce, which CryptoKit's default provides.
- The key is derived once at unlock and kept in memory as a `SymmetricKey`. The password is never stored. "Lock" drops the key and the in-memory conversation.
- A failed GCM open throws `ParleyError.wrongPassword`.
- A fork of an encrypted conversation is also encrypted, with the same `EncryptionKey` (same salt and key, fresh nonces).

Plain file layout:
```json
{ "format": "parley.conversation", "version": 1, "encrypted": false, "conversation": { ...Conversation... } }
```
Shared encoding rules:
- JSONEncoder uses `.iso8601` dates, `.prettyPrinted` and `.sortedKeys` for plain files, and Data as base64 (the default).
- The file name is always `<UUID>.json`. A title is never used in a file name, so nothing leaks.
- Writes are atomic (`Data.write(to:options:.atomic)`, which writes a temp file in the same directory and renames it). Only the final bytes are ever written, so ciphertext only for encrypted files. POSIX permissions are 0600 on the file and 0700 on directories the app creates.

## ParleyCore API contracts (exact signatures, public)

### Crypto.swift (agent: core-storage)
```swift
import CryptoKit
public struct EncryptionKey: Sendable {           // not Codable, never persisted
    public let key: SymmetricKey
    public let salt: Data
    public let iterations: Int
    public init(key: SymmetricKey, salt: Data, iterations: Int)
}
public enum ConversationCrypto {
    public static let kdfName = "PBKDF2-HMAC-SHA256"
    public static let cipherName = "AES-256-GCM"
    public static let defaultIterations = 600_000
    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey // CCKeyDerivationPBKDF, 32 bytes
    public static func newKey(password: String, iterations: Int = defaultIterations) throws -> EncryptionKey // random 16-byte salt via SecRandomCopyBytes
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data   // returns combined
    public static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data    // throws ParleyError.wrongPassword on auth failure
}
```

### ConversationFile.swift (agent: core-storage)
```swift
public struct ConversationFileHeader: Sendable, Hashable {
    public let id: UUID
    public let isEncrypted: Bool
    public let title: String?        // nil when encrypted
    public let updatedAt: Date?      // nil when encrypted
    public let messageCount: Int?    // nil when encrypted
}
public enum ConversationFile {
    public static let format = "parley.conversation"
    public static let version = 1
    public static func fileName(for id: UUID) -> String                     // "<UUID>.json"
    public static func encode(_ conversation: Conversation, encryption: EncryptionKey?) throws -> Data
    public static func peek(_ data: Data) throws -> ConversationFileHeader  // throws notAConversationFile / unsupportedVersion / corruptFile
    public static func decodePlain(_ data: Data) throws -> Conversation
    /// Derives the key (slow, ~0.3–1 s), so call it off the main thread.
    public static func decodeEncrypted(_ data: Data, password: String) throws -> (Conversation, EncryptionKey)
    /// For re-opening with an already-derived key (e.g. after a fork). Fast.
    public static func decodeEncrypted(_ data: Data, key: EncryptionKey) throws -> Conversation
    public static func write(_ data: Data, to url: URL) throws   // creates parent dir (0700) if missing, atomic, chmod 0600
}
```

### Keychain.swift (agent: core-storage)
```swift
public enum KeychainStore {
    public static let service = "local.parley.chat.apikey"
    public static func setAPIKey(_ key: String, for providerID: UUID) throws  // upsert kSecClassGenericPassword, account = providerID.uuidString, kSecAttrAccessibleWhenUnlocked; empty string deletes
    public static func apiKey(for providerID: UUID) throws -> String?        // nil if errSecItemNotFound
    public static func deleteAPIKey(for providerID: UUID) throws             // ignore errSecItemNotFound
}
```
The keychain must never be synced, so `kSecAttrSynchronizable` stays false (the default). `KeychainMCPSecretStore` uses the same calls under its own service, `local.parley.chat.mcp`, with one item per server (see "MCP client"), so accounts cannot collide with API keys.

### Streaming.swift (agent: core-network)
```swift
public struct ChatDelta: Sendable, Equatable {
    public var content: String?
    public var reasoning: String?        // from delta.reasoning_content OR delta.reasoning
    public var usage: TokenUsage?
    public var finishReason: String?
    public init(content: String? = nil, reasoning: String? = nil, usage: TokenUsage? = nil, finishReason: String? = nil)
}
/// Splits an SSE byte stream's lines into JSON payload strings.
public struct SSEDecoder {
    public init()
    /// Feed one line, without its newline. Returns 0..n complete data payloads. "[DONE]" is returned verbatim.
    /// Handles "data:" with or without a space, ignores ":" comments, "event:", "id:" and "retry:".
    /// Spec-compliant: multiple data lines join with "\n" until a blank line. Because URLSession's
    /// AsyncBytes.lines drops blank lines, a data line whose accumulated buffer already parses as
    /// complete JSON is also emitted immediately.
    public mutating func feed(line: String) -> [String]
    public mutating func finish() -> [String]   // flush the remaining buffer
}
public enum ChunkParser {
    /// Parses one chat.completion.chunk JSON payload. Throws ParleyError.api(message) if the payload is {"error":{...}}.
    public static func parse(_ payload: String) throws -> ChatDelta?
}
/// Accumulates deltas into displayable content/reasoning. Handles inline <think>...</think>
/// split across chunk boundaries, and output containing only a closing </think>
/// (prompt template opened the tag): everything before it is reclassified as reasoning.
public struct StreamAccumulator: Sendable {
    public private(set) var content: String
    public private(set) var reasoning: String
    public private(set) var usage: TokenUsage?
    public private(set) var finishReason: String?
    public private(set) var reasoningStartedAt: Date?
    public private(set) var reasoningEndedAt: Date?   // set when the first content token after reasoning arrives, or at finish
    public var isReasoning: Bool { get }              // true while currently inside reasoning
    public var reasoningDuration: Double? { get }
    public init()
    public mutating func apply(_ delta: ChatDelta, now: Date = Date())
    public mutating func finish(now: Date = Date())   // flushes any held-back partial tag text
}
```
Other `<think>` rules:
- Recognize the tags `<think>` and `</think>`, case-sensitively. Also accept `<thinking>` and `</thinking>`.
- Hold back a trailing partial tag prefix, such as `"<thi"`, until the next chunk arrives or `finish()` is called.
- Trim leading newlines from the content that follows `</think>`.

### ChatClient.swift (agent: core-network)
```swift
public struct ChatRequestOptions: Sendable {
    public var model: String
    public var systemPrompt: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    public init(model: String, systemPrompt: String = "", temperature: Double? = nil, maxTokens: Int? = nil, reasoningEffort: ReasoningEffort? = nil)
    public init(settings: ConversationSettings)
}
public final class ChatClient: @unchecked Sendable {
    public init(baseURL: String, apiKey: String?) throws   // validates scheme http/https + host; throws invalidBaseURL
    public let baseURL: URL
    /// GET {base}/models → data[].id sorted
    public func listModels() async throws -> [String]
    /// POST {base}/chat/completions with stream:true. Non-2xx → ParleyError.http(status, body ≤ 2000 chars).
    /// Cancelling the consuming Task cancels the request.
    public func streamChat(messages: [Message], options: ChatRequestOptions) -> AsyncThrowingStream<ChatDelta, Error>
    /// Pure, for tests. Returns the JSON body dictionary.
    public static func buildRequestBody(messages: [Message], options: ChatRequestOptions) -> [String: Any]
    /// True if the host is loopback, private RFC1918, link-local, *.local, or a CGNAT/Tailscale 100.64/10 address.
    public static func isLocalHost(_ host: String) -> Bool
}
```
Request body rules:
- Body fields: `model`, `stream: true`, `messages`, and optionally `temperature`, `max_tokens`, `reasoning_effort` (only when non-nil). "None (no thinking)" adds the per-server fields of "No thinking" below instead of an effort.
- `streamChat` also sends `stream_options: {include_usage: true}` (`buildRequestBody(…, includeUsage: true)`). If the server answers HTTP 400/422 with a body that names `stream_options` or `include_usage`, the same request is sent once more without it, and the base URL is remembered in a process-wide, memory-only set (`StreamOptionsSupport`) so later clients leave it out. Other 400s are never retried. The "no thinking" fields have their own retry (see "No thinking" below); the two can happen in one call, in either order, each at most once.
- If `systemPrompt` is not blank, it is sent first with role `system`.
- User messages with no images send content as a string. Text attachments are appended as ``"\n\n<file name=\"NAME\">\nTEXT\n</file>"``.
- User messages with images send content as an array: `[{"type":"text","text":...}, {"type":"image_url","image_url":{"url":"data:<mime>;base64,<b64>"}}...]`.
- Assistant messages send only `content`, plus `tool_calls` for tool rounds when the request carries `tools`. In ReAct, rounds go out as text (see "ReAct text mode"). **Never** send `reasoning` or `reactThought`.
- Skip assistant messages whose content is empty, for example a failed request with an error set. Partial (stopped) assistant content is sent as is.
- Headers: `Authorization: Bearer <key>` only if the key is non-empty, `Content-Type: application/json`, and `Accept: text/event-stream`.

Session: an ephemeral `URLSessionConfiguration` with:
- `urlCache = nil`
- `httpCookieStorage = nil`
- `httpShouldSetCookies = false`
- `requestCachePolicy = .reloadIgnoringLocalCacheData`
- `timeoutIntervalForRequest = 600`

Do no logging of message content.

### Attachments.swift (agent: core-network)
```swift
public enum AttachmentLoader {
    public static let maxTextBytes = 1_000_000
    public static let maxImageDimension = 2048
    public static func load(url: URL) throws -> Attachment
    public static func image(data: Data, filename: String) throws -> Attachment
    public static func isSupported(url: URL) -> Bool
}
```
Loading rules:
- Images are anything that conforms to `UTType.image`. Downscale with ImageIO (`CGImageSourceCreateThumbnailAtIndex`, with transform applied and long edge ≤ 2048), then re-encode. Use PNG if the image has alpha and the result is under 4 MB; otherwise use JPEG at quality 0.85.
- Text files are anything that conforms to `.text` or `.sourceCode`, plus json, yaml, xml, csv, md, and anything else that decodes as UTF-8 without NUL bytes. Content over 1 MB throws `attachmentTooLarge`.
- Anything else throws `unsupportedAttachment`.

## App target (agent: app). Files under `Sources/Parley/`

Suggested files:
- `ParleyApp.swift`: `@main`, with a `WindowGroup` plus a `Settings` scene and an `NSApplicationDelegateAdaptor` that flushes saves on terminate.
- `AppSettings.swift`
- `AppState.swift`
- `ConversationSession.swift`
- `Views/*.swift`

Persistence of app settings uses `UserDefaults`, never iCloud:
- `providers` as a JSON-encoded `[Provider]`, plus `defaultProviderID`.
- `defaultDirectoryPath`, which defaults to `~/Library/Application Support/Parley/Conversations`. That location is not iCloud-synced. Settings shows a note that Desktop and Documents may be synced by iCloud.
- `extraConversationPaths: [String]`, which holds file paths only. Titles are never stored here.
- UI preferences.

The library (sidebar) lists the union of the `*.json` files in the default directory and `extraConversationPaths`, read with `ConversationFile.peek`:
- Encrypted entries show "🔒 Encrypted conversation" until unlocked, and the title only while unlocked in memory.
- Sort by `updatedAt`. Encrypted entries fall back to the file's modification date.
- The sidebar also offers "Open conversation file…" (NSOpenPanel), which adds the file to the extra paths, and "Reveal in Finder".

Each `ConversationSession` (`@Observable`, `@MainActor`) holds:
- `conversation`, the file URL, and `encryption: EncryptionKey?`
- streaming state: an accumulator mirror and a `Task` handle
- the debounced save

The save path works like this:
- Snapshot the conversation value on the main actor.
- Run `ConversationFile.encode` and `write` on a serial background queue.
- Save immediately on send, completion, stop, error, rollback, fork, edit, and settings change.
- While streaming, also save every ~2 s with an in-progress assistant message (`isComplete=false`).
- Window and state restoration must not persist conversation content. Do not use `@SceneStorage` for content.

Features:
- **Sidebar:**
  - Conversation list with title, lock icon, and relative date.
  - New Chat (⌘N) opens a sheet with:
    - a title (optional; the default is auto-titled from the first user message, truncated to 40 characters)
    - a directory, defaulting to the Settings default, with a "Choose…" button
    - an Encrypt toggle with password and confirm fields
  - Context menu: Rename, Encrypt…/Change password…, Remove encryption, Lock, Reveal in Finder, Remove from list, Delete file (with confirmation; moves to the Trash via `FileManager.trashItem`).
- **Chat view:**
  - The toolbar has a provider picker, a model picker (from `listModels` plus free text), and a button that opens a per-conversation settings popover (system prompt, temperature, max tokens, reasoning effort).
  - Each message row shows the role, markdown content, and attachments: image thumbnails, and text-file chips that preview on click.
  - Each row has a hover action bar:
    - **Copy** for both user and assistant messages. It writes to NSPasteboard with `prepareForNewContents(with: .currentHostOnly)`, which keeps Universal Clipboard from syncing it to other devices.
    - **Rollback to here** (with confirmation): `truncate(keepingThrough:)`.
    - **Fork from here**: `forked(through:)`, saved in the same directory, inherits encryption, and gets selected.
    - **Edit & resend** (user messages only): puts the text and attachments in the composer and truncates before that message.
    - **Regenerate** (assistant messages only): truncates before it and resends.
  - Assistant thinking appears as a collapsible "Thinking… / Thought for N s" disclosure. It is expanded while streaming and collapsed afterwards. Thinking renders in a secondary, monospaced-ish style.
  - Error text renders in red under the message, with a Retry button.
  - Auto-scroll to the bottom while streaming.
- **Composer:**
  - A multi-line TextEditor. Enter sends and Shift-Enter inserts a newline.
  - Attach with a paperclip button (NSOpenPanel), drag-and-drop onto the chat, or paste of images.
  - Pending attachments show as removable chips.
  - The Send button becomes Stop while streaming. Stop cancels the task and keeps the partial message with `isComplete=false`.
- **Settings window:**
  - Providers list: add, remove, and edit name, base URL, default model, and API key. The API key is a SecureField saved to `KeychainStore`; the key is never stored in UserDefaults.
  - A "Test connection" button that calls `listModels`.
  - A warning when the base URL is http and the host is not local (`isLocalHost`: loopback, LAN, Tailscale 100.64/10; for this warning only also MagicDNS `*.ts.net`): the API key and chats travel unencrypted over the internet; it names the same URL with https.
  - A default directory chooser.
  - A privacy note: "Parley only contacts the API endpoints you configure. No telemetry."
- **Markdown rendering:**
  - The app must never fetch remote URLs, so do not use AsyncImage for model output.
  - Implement a small block renderer:
    - Split on fenced code blocks. Code renders monospaced in a rounded background with a per-block copy button.
    - Other paragraphs render with `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`.
    - Headings (`#`) are bold and larger. List lines keep their bullets.
  - `.textSelection(.enabled)`.
  - Links open only after a click and a confirmation (`Views/LinkConfirmation.swift`). A tool result can tell a model to write a link whose address carries the conversation, and the link's text can say anything, so this is the last step before that data leaves the Mac:
    - `MarkdownParser.inline` is the only place model text becomes links. It rewrites each link to `parley-link:<base64 of the address>` (`PendingLink.inert`), which nothing can open, and strips the link from anything `PendingLink` refuses, so it reads as plain text. Only http and https open, so `mailto:` no longer does, and only with a host that a browser reads the way the sheet shows it: not percent-encoded (`good.example%2Eevil.net` is at evil.net) and, if it ends in a number, a canonical dotted quad (`010.010.010.010` is 8.8.8.8, and `https:evil.example` has no host at all). The system's menu on a link is drawn out of process and differs by macOS version, so nothing relies on it going through `OpenURLAction`: without the gate an address gets nowhere. A rich-text copy of a selection therefore carries the inert form; Copy Message keeps the markdown.
    - `ContentView`'s `OpenURLAction` is the gate: `AppState.requestOpen` decodes the link into `pendingLink` and `LinkConfirmationSheet` shows it. `confirmPendingLink` calls `AppState.openLink` (`NSWorkspace`; a stub in tests and the snapshot harness) with the URL the sheet showed. Never reopen through `@Environment(\.openURL)`: that is the gate.
    - The sheet shows `URL.absoluteString` in full, not the link text. Punycode and percent-encoding stay, since decoding brings the lookalikes back. `ToolDisplay.address` also escapes anything outside printable ASCII as `\u{…}`, wider than `visible`, because right-to-left letters reorder a line. Foundation already returns ASCII on current macOS, so that is a second line of defence. The host has its own line for `https://docs.example@notes.example/`, and its end is kept when it is too long for two lines. A long address scrolls, and `ToolTextBlock` says so from the measured height: overlay scroll bars may show nothing, and a payload sits at the end.
    - Open has no keyboard shortcut and uses `ToolApprovalCard.armDelay`, so the second click of a double-click cannot land on it. Locking a conversation clears `pendingLink`: the address may hold what was locked.
    - Not checked by a test: what the right-click menu offers on a link. The snapshot harness cannot read it. A click on a link in selectable text did reach the gate, with real events in an activated app (the harness itself never activates, so it sets the state through `requestOpen`). Snapshot states: `link-confirmation`, `link-confirmation-narrow`.

Encryption UI flows:
- **Unlock:** selecting a locked conversation shows a password field. Decoding runs off the main thread, and a wrong password shows an error.
- **Encrypt existing:** set a password and confirm it, `newKey` on a background thread, then save. Show an alert: "The previous unencrypted file was overwritten in place. On SSDs/APFS this is not a secure erase; older copies may exist in backups or snapshots."
- **Remove encryption:** confirm, then save as plain.
- **Lock:** flush the save, then drop the session.

## Tests (`Tests/ParleyCoreTests`)
- **Crypto:** round trip, wrong password, tampered payload, tampered header (salt or id) fails, nonces differ between saves.
- **ConversationFile:** plain round trip, peek on both kinds, encrypted header carries no title.
- **SSEDecoder:** handles `data:` with and without a space, comments, `[DONE]`, and multi-line data.
- **ChunkParser:** `reasoning_content`, `reasoning`, `content`, usage, and the error object.
- **StreamAccumulator:** a `<think>` tag split across chunks (`"<thi"`, `"nk>abc</th"`, `"ink>\nhello"`), an orphan `</think>`, no tags, and `reasoning_content` followed by content (timing set).
- **buildRequestBody:** no reasoning sent, images as parts, the system prompt first, empty assistant messages skipped.
- **Conversation:** `truncate`/`forked` boundaries.

`tools/mock_server.py` (Python 3 stdlib) serves an OpenAI-compatible mock on 127.0.0.1:8765:
- `/v1/models`
- `/v1/chat/completions`, streaming. Its mode is picked by model name: `mock-reasoning-content`, `mock-reasoning`, `mock-think-tags` (tags split across chunks), `mock-orphan-think`, `mock-error` (HTTP 400 with a JSON error), and `mock-slow` (one token every 200 ms, for testing Stop).
- It echoes the last user message and the number of images received, so you can confirm that attachments arrived.
- `mock-react*` models are servers without tools that answer in ReAct text; see the file's header.
- `mock-tools*` models script tool calls in each server's chunk shape (the user text picks the call: `tool=<name> args=<json>`), and any request with tool data is refused unless every call has its tool message. `tools/mock_mcp_server.py` is an MCP server for stdio and HTTP (standard library only, bound to 127.0.0.1); see its header for the tools and behaviors.
- It sends the final usage chunk only when the request has `stream_options.include_usage`. `mock-no-stream-options` rejects `stream_options` with HTTP 400; `mock-timings` adds llama.cpp `timings` to the last chunk; `GET /mock/requests` returns counters.
- A second argument picks the server flavor for context discovery: `lmstudio` (default; `/api/v1/models`, `/api/v0/models`, in-memory `/api/v1/models/load` and `/unload`, where loading an already-loaded model adds a `key:2` instance as LM Studio does), `lmstudio-v0`, `llamacpp` (`/props`, `meta`), `vllm` (`max_model_len`), `ollama` (`/api/ps`), `plain`, `strata-share` and `strata-engine` (see Strata below). An optional third argument is an API key the Strata flavors require (keyless by default, so app tests and the snapshot harness never need a Keychain item).
- `GET /mock/last-request` (every flavor) returns the last chat request body without its messages, so tests can assert which fields were sent.
- "No thinking": `llamacpp` and `vllm` honour `chat_template_kwargs.enable_thinking: false` and `ollama` honours `reasoning_effort: "none"` (the reasoning models then answer without thinking); `lmstudio`, `lmstudio-v0` and `plain` ignore both and still stream thinking. Flavor `openai-strict` (like `plain`) refuses `reasoning_effort: "none"` with OpenAI's 400 (`param: "reasoning_effort"`, `code: "unsupported_value"`); its `mock-always-reject` refuses every request that way and `mock-overflow` answers an OpenAI overflow 400. `mock-refuse-unnamed` refuses `"none"` with a 400 that does not name the field (Ollama's `invalid reasoning value: "none"`). `/mock/requests` counts `thinking_off_rejected`. `MOCK_PROBE_DELAY=<s>` delays native GETs (not `/v1/models`).

## MCP client
Parley is an MCP client: it connects to servers the user configures, offers their tools to the model as OpenAI `tools`, runs the returned `tool_calls` through `tools/call` after approval, feeds the results back and loops until the model answers.

Scope for v1: stdio and Streamable HTTP, tools only, static HTTP headers or OAuth sign-in. **Out of scope:** resources, prompts, sampling, elicitation, roots, tasks, HTTP+SSE, `Last-Event-ID` resumption, progress, parallel execution of calls, images in results, a server registry, reading other apps' config files, idle shutdown, a sandbox for stdio servers, MCP-server mode.

Rules that must keep holding:
- **No servers by default, nothing starts on its own.** A server starts only on a send in a conversation that lists it, or on Connect in Settings. Constructing AppState reads no secret and starts no process. No telemetry, registry lookup or auto-discovery. `.well-known` is fetched only inside a Sign In the user pressed, never on a 401 (see "MCP sign-in"). A timer never restarts anything.
- **No tools, no change.** With no enabled tools the request has no `tools` key and is byte-identical to the version before MCP (`NoToolsGoldens`). `tool_choice` is never sent; an empty `tools` is never sent.
- **Tool-shaped messages go out only when the request carries `tools`.** Otherwise rounds are flattened into assistant text (`Message.flattenedForRequest`). This one rule covers the disabled-server, refused and round-cap cases. `ChatClient.sendsTools(_:)` and `sendsReact(_:)` alone decide: a ReAct request carries no `tools` and replays rounds as Action and Observation text, and everything `sendsTools` decides must also look at `sendsReact` (body shape, sorted keys, `answerNow`, the size guard's wording, the guard in `runReply`). A reply still open, going out with neither, then ends in a request-only user turn (`ToolResultText.answerNow`): llama.cpp and Ollama would continue a trailing assistant turn instead of answering it.
- **Stopped means stopped.** A reply's catalog dates from its start, so `runCalls` reads the server and tool list again before a card and after it: what was switched off, unticked or removed in between is `notCalled`. Stop, a saved edit and Delete mark the connection (`stoppedByUser`, `forget`), so `call` restarts only what crashed; only `catalog` and `connect` start what the user stopped.
- **stderr stays in memory.** It can hold tokens. `MCPError.summary`, which leaves out stderr and local folders, is what notes and tool results get; `errorDescription` is for the Settings status and the log, and `clearLogs` removes it from there too.
- **Server JSON is bounded.** Every parse of what a server sent goes through `JSONValue.parsed` or `JSONValue(jsonData:)`: 128 levels (stacks here are 512 KiB, and JSONSerialization's own limit is 512), no number that cannot be written back (`-1e999` parses to infinity, and writing that raises an exception `try?` cannot catch).
- **Approval is what is sent.** The card and `tools/call` use the same `ToolArguments.parse` value. The card has no keyboard shortcut: Return belongs to the composer. Approval never times out. `readOnlyHint` never skips it.
- **Untrusted text.** A tool description reaches the model only as that tool's `description`; a result only as a tool message or the marked flattened form. Neither goes into the system prompt; `instructions` is not used. One carve-out, for ReAct only, which has no other way to reach a model without `tools`: descriptions and schemas go into the system message between fences, with text saying they were written by tool servers and are data, and results go into user turns between fences (see "ReAct text mode"). The conversation's id is in the file header, so a fence is not secret: its closing marker is broken in the text at render time. The UI shows both with `Text(verbatim:)`, labelled, with control and bidi-override scalars escaped (`ToolDisplay.visible`).

### Storage
`Message.toolRounds: [ToolRound]?`, `toolNotes`, `toolDefinitionTokens`; `ConversationSettings.mcpServerIDs` (ids only, so a file can never name a command or URL). ReAct adds `ConversationSettings.toolMode` and `Message.reactThought`. All optional, the file version stays 1: an older Parley shows the final text and drops the rounds if it saves.

Top-level `content`/`reasoning`/`usage`/`stats` always hold the current or final round. A call and its result live in one `Message`, so rollback and fork stay atomic. `ToolCallRecord.startedAt` is saved before `tools/call` goes out; a nil `result` means the app died, and replay synthesizes one (`replayResult`). The file is not rewritten on load. Results are stored as the model saw them (truncated); the raw result is never stored.

Config: `AppSettings.mcpServers` (`MCPServerConfig`: command, names, flags, the URL's host, two SHA-256 fingerprints) and `maxToolRounds`. Secrets: one Keychain item per server (service `local.parley.chat.mcp`, account = server UUID, JSON `MCPServerSecrets`) holding arguments, the URL, env values and header values, because pasted configs put tokens in all four. `AppState.saveServer` writes the Keychain first, so a failed write stores nothing. Read at server start and when the editor opens, never at launch. Tests and the snapshot harness use `InMemoryMCPSecretStore`.

"Always Allow" is per server and tool, pinned to `MCPTool.fingerprint`, cleared when `identityFingerprint` (kind, command, arguments, URL, working folder, the server's own PATH) changes, revocable in Settings. A different fingerprint brings the card back with `definitionChanged`.

### The reply loop (`ConversationSession.runReply`)
One Task from send to end, so Stop reaches it wherever it is; `endStreaming` runs only at the very end. Every `await` is followed by `isCurrent(messageID)`.

```
wait for the server kind when servers are listed (a Strata runtime model must not lose tools silently)
ignoresTools → note, start nothing | remembered refusal → note, start nothing | else host.catalog
  (ReAct skips both gates: those servers are what it is for)
loop: beginRound → streamRound(history + inFlightCopy)
  ReAct request: native calls → .nativeCallsIgnored note, then the round's text decides (parse)
  no calls → finishReply
  no tools or ReAct in this request, or finish_reason length → .callsNotRun note, finishReply
  commitRound → runCalls → roundsRun += 1; at maxToolRounds: omitsTools, .roundLimit note
```

- `commitRound` moves the top-level fields into a `ToolRound` and resets accumulator, meter and `liveGeneration` in the same step, or Stop would write the round back as the final one and the strip would count it twice.
- `finishReply`: empty text is an error only with no rounds; with rounds it is the `.emptyAfterTools` note. In ReAct the shown text can be empty although text came (an Action alone, bare labels): the error then says that (`nothingToShow`), never that the server sent nothing, and an Action cut off after a round has its `.callsNotRun` note alone.
- `finalizeStreamingMessage` is the single place for Stop, Lock, close and quit: `answerApproval(.cancelled)` (a cancelled Task does not resume a continuation), then `resolveUnfinishedCalls` (`notRun` or `interrupted` by `startedAt`). `answerApproval` is idempotent.
- Calls run sequentially in index order. Malformed arguments and unknown tools ask nothing and run nothing: the model gets a result saying why.
- A crash mid-call yields the `crashed` text and is never re-run. A broken stream on `tools/call` is never re-issued, because that could repeat a side effect without approval.

Refusals: `ToolsSupport` classifies 400/404/422/500/501 bodies; `streamChat` retries once without tools and yields `toolsRejected` on the 2xx. `.unsupported` is remembered per provider + model on the AppState instance (`toolRejections`, memory only); `.definitions` is not, because one bad schema from one server must not turn tools off for the model.

Context: a fresh `GenerationMeter` per round, so tool time never lowers tok/s. `ContextBudget.usage` anchors on the newest counted round while a reply is in flight, and adds definitions only when the anchor did not already carry them. `toolResultBudget` clamps each result to half the room left (at least 2,000 characters), so one result cannot end a small context with an overflow.

### ReAct text mode (`Sources/ParleyCore/ReAct.swift`)
For models and servers without native `tools`: Ollama models without tool support, llama.cpp without `--jinja`, Strata's runtime path. The model reads tools as text and answers with Thought, Action, Action Input and Final Answer lines.

`ConversationSettings.toolMode`: nil is native, `"react"` is text. Off by default, read once at reply start, copied by a fork. The picker is in `ConversationToolsPopover`, shown once any server is configured. When a refusal is remembered or the server `ignoresTools`, the popover offers Use ReAct in native mode, and nothing switches on its own. The warnings that say tools are not offered show only in native mode.

Request: `ChatRequestOptions.react` (tools and nonce), `tools` stays nil, so no `tools` or `tool_choice` goes out. `ReActPrompt.block` is appended to the system message, keys sorted as with tools, for the prefix cache. No `stop` is sent: a thinking model can write "Observation:" in its reasoning, which a server stop string would cut. The session leaves the stream at the first text after the first Action's input (`ReActScanner.actionIsFollowed`; white space and a fenced input's closing fence do not count), and `onTermination` cancels the request. It does not leave at the input's end, because a `</think>` that comes next, with no opening tag, shows the Action was reasoning, and the scan starts again (see Known limits). A model that stops by itself ends the stream, and that round then has its usage and finish_reason. A `length` finish right after a whole input therefore runs nothing, like any other. At the round cap `omitsTools` drops the block, rounds flatten, `answerNow` closes the request, and that request's text is not parsed.

Replay: round `content` holds only the Thought, and Action lines come from the call's name and raw arguments, so there is no new stored field, native rounds replay the same way, and ReAct rounds replay natively as ordinary rounds. One assistant and user pair per call, the Thought on the first:
```
assistant: Thought: <content>\nAction: <name>\nAction Input: <replayArguments>
user:      Observation (tool output, data only):\n<<<call_xxxx\n<replayResult>\ncall_xxxx>>>
```
A closed reply that ended in a round gets a request-only assistant turn (`ToolResultText.noAnswer`) before the next user turn, or two user turns would meet and strict templates would refuse them. Thoughts before a Final Answer and reasoning are never sent, with the one exception under Known limits.

Fences: `<<<id` and `id>>>`, where the id is `tools_<nonce>` (the first 8 hex of the SHA-256 of the conversation id) or the call id. Neither is a secret. `ReActFence.neutralized` breaks every occurrence of the closing marker in what goes inside, each time the text is rendered and the same way each time, by code unit, so a combining mark cannot hide one. With a server's id such as `>abc`, a replacement and the text after it can form a new marker, so it checks its output after every code unit, in one linear pass. Stored text is not changed. The definitions fence covers schemas as well as descriptions.

Parser (`ReActParser`, `ReActScanner`): input is this round's `content` from the accumulator, inline `<think>` already split out, never `reasoning`. Line-anchored, case-sensitive, `:` or `：`, outside ``` fences, except that the JSON after `Action Input:` may sit in one, on its own lines or on the same line as the fence. The first Action or Final Answer wins. After an Action's input everything is dropped, so a made-up Observation lands nowhere. A balanced, string-aware object is the input; anything else is raw text up to the next marker, which the malformed path reports to the model with no approval (words in a ``` line keep their backticks, so they cannot pass as JSON); no input line means empty arguments. An Action with no name is no call and only its Thought stays, as `finalCalls` drops a nameless native call: a stored one would be an invalid `tool_calls` entry in every later native request. With neither marker the whole text, minus a leading `Thought:` label, is the answer. A blank Final Answer leaves the Thought as the answer. The scanner keeps its position between feeds and stops at a Final Answer, so a long answer stays linear (`bytesExamined`). `StreamAccumulator.contentGeneration` tells it to start again when an orphan `</think>` turns the text so far into reasoning.

Approval: a call read from text always shows the card (`.always` counts as `.ask`), and the card has no Always Allow, because text can be an echo of tool output, so it is weaker evidence than a structured call. `.changed` still warns. Stored entries are untouched and work again in native mode. The name must match exactly (`exactBinding`), in `commitRound` and in `runCalls`; the near match is for servers that normalize structured names. Native `tool_calls` arriving in ReAct never run (`.nativeCallsIgnored`, a note of its own because it sits on replies that ended well and on replies whose text call ran).

Display: `applyAccumulator` shows the scanner's live text, for Stop and Lock too: the label stripped, cut at the first Action line, a partial marker held back, only the answer after Final Answer. A round's `content` is the Thought. A final message's `content` is the answer, so Copy and `visibleText` stay clean. Its Thought is `Message.reactThought`, not `reasoning`: `endStreaming` would raise a false `thinkingOffIgnored`, and the duration would be wrong. It shows in a collapsed section above the answer and counts like reasoning in `ContextBudget`.

Leaving the stream early means a round has no `usage` or `finish_reason`. Its stats fall back to the meter's chunk count, marked estimated, and `ContextBudget.usage` estimates the round. The Final Answer request runs to its end and is counted as usual. `message.toolDefinitionTokens` is the estimate of the whole block.

Known limits: nothing here has run against a real model or server, only `tools/mock_server.py`. The block's wording is untested on real models, and some will not follow it. With a template that opens `<think>` itself, reasoning arrives as content until `</think>`. A complete Action with `</think>` right after it is taken as reasoning. One with more reasoning after it ends the stream and brings up a card (never a call without approval). Once that card is answered, Allow or Deny, the text before the Action goes back to the model as the round's Thought, which is the one way reasoning is sent, and the answer the model was on its way to is never read; it answers again after the Observation. A server that goes silent right after an input, without ending the stream, holds the card back until it writes, ends, or the user presses Stop. An inline `<think>` inside an argument string is split out of the arguments; the card shows what is left, which is what is sent. A failed reply, skipped in every request, can still leave two user turns in a row, as in native mode and plain chat, and a strict template refuses that. The idle "Tool definitions" figure is the native estimate; a reply stores the block's.

### MCP core (`Sources/ParleyCore/MCP/`)
- `MCPToolHost` is the contract; ConversationSession sees only it. `MCPConnectionManager` (actor, owned by AppState) keeps one process per server, shared by conversations, lazy, restarted on next use after a crash, at most 3 crashes in 60 s. `disabledTools` are filtered in `catalog`; `connectionFingerprint` decides when a connection is replaced.
- **Era detection opens with `initialize`** and falls forward to `server/discover` on rejection, reversing the spec's SHOULD for dual-era stdio clients: legacy is the deployed norm, and the probe stalls or kills exactly those servers. A dual-era server loses nothing, since Parley uses tools only.
- stdio: `posix_spawn` with its own process group and `F_SETNOSIGPIPE`, `killpg` on stop, swept again if the leader left first. A descendant that calls `setsid` escapes; crash and force quit rely on stdin EOF. The child gets a minimal environment plus the server's own. `ShellPATHResolver` runs `$SHELL -l -c` once, lazily, for bare commands only. Never `-i`: it would source `.zshrc`, whose plugins can touch the network.
- HTTP: the same ephemeral session and redirect refusal as ChatClient. A request of a send or Connect may renew a token and is retried once after a 401, which says the server did not run it (not the broken-stream case, where a call may have run). Notifications, replies and DELETE send the token as it stands. User headers first, protocol headers last, CR/LF refused. Any message over 16 MiB is a transport failure.
- Names: `<server>__<tool>`, lower snake case, at most 64 characters, deterministic (`MCPToolNamer`), stored on the record so old rounds replay unchanged. `binding(forFunctionName:)` also accepts a unique match ignoring case and punctuation, because LM Studio normalizes names.

### MCP sign-in (`MCPOAuth*.swift`, MCP 2026-07-28 authorization)
The user approved these defaults:
1. Discovery runs only inside a Sign In the user pressed. A 401 stops: one request, no lookup (`unauthorizedSaysSoAndDiscoversNothing`).
2. Another host is contacted only after the sheet (`MCPSignInReviewSheet`) names it and what it receives. That covers a `resource_metadata` on another origin, the provider, and any further host in the provider's metadata. A provider that is not the MCP server gets a plain warning: the server will hold a token that may work beyond it. With several authorization servers the user picks one, and only that one is contacted. Hosts count with their port.
3. Client: the one the user entered, else a stored registration for this issuer, else Dynamic Client Registration, else "enter a Client ID". The editor has optional Client ID, Client Secret and a fixed callback port, and shows the redirect URI. Parley hosts nothing, so it has no metadata document of its own; an https URL entered as Client ID works as one on a provider that advertises support.
4. A token is renewed only inside a send or Connect, never on a timer. `offline_access` is requested when the provider lists it, beside other scopes only. Sign Out deletes locally and contacts no provider; closing the connection sends the usual session DELETE.
5. The sheet says the server's address goes to the provider and into browser history. The spec requires `resource`, and URLs can hold secrets, so a URL with a user or password cannot sign in.
6. Parley cannot tell which account was chosen in the browser, so every Sign In clears Always Allow for that server, through `willSignIn`, before the new token can be used. Afterwards would let a reply in its tool loop run approved tools under the new account.

Flow (`MCPOAuthSignIn.run`): the remembered challenge or one tokenless probe; Protected Resource Metadata (header URL, path-inserted, root); sheet; authorization server metadata in the spec's order, where `issuer` must be identical and S256 listed; sheet again for new hosts; client, with the listener bound first so registration gets the real redirect URI; browser through `NSWorkspace`; callback; code exchange. Scope order: the challenge, else the metadata's `scopes_supported`, else omitted, always with what was requested before, so a step-up keeps it.

`MCPOAuthResource.matches`: same origin, and the metadata's path equals the server's or is a whole-segment prefix of it, because a root document names the origin. The validated metadata string is what is stored and sent, verbatim, on authorization, code exchange and refresh. The same rule decides whether a stored token may go to the URL now.

Callback (`MCPOAuthLoopback`): POSIX sockets, 127.0.0.1 only, because NWListener cannot combine a required local address with an ephemeral port. The spec allows only localhost or https redirects, so no custom URL scheme. A request counts only with the exact path, this listener's own Host and the right `state`; anything else gets a 400 and leaves it listening. `state` is set before the browser opens, because a live session can answer at once. Then the RFC 9207 table runs before anything in the response is read.

Storage (`MCPOAuthStore`): service `local.parley.chat.mcp.oauth`, two items per server, never in `MCPServerSecrets`, whose item the editor's Save rewrites from its draft. Account = server UUID holds tokens, expiry, issuer, resource, token endpoint, requested scopes. Account = UUID + `.client` holds clients by issuer, written as soon as they exist: a registration so an abandoned attempt leaves no second record, a typed-in client so its ID and secret stay tied to that provider. `invalid_grant` keeps the client; `invalid_client` removes a registered one and never a typed-in one. Tokens are never in a fingerprint. `description` on both types is redacted.

Races (`MCPOAuthBroker`, an actor, one per server, outliving connections): every write and delete of the item happens there. `generation` is what a refresh started from; `signInEpoch` is what a Sign In in the browser started from. `clear` moves both and removes the item in one step, so nothing late can bring a token back after Delete, a URL change or Sign Out. A refresh is shared by all waiters and runs in its own task and session, because a public client's refresh token is spent the moment the provider answers: a caller's timeout or Stop ends only its wait, and a token answer is never discarded. A save the Keychain refuses leaves the new tokens in memory, marked `unsaved`, so a reconnect does not bring back the spent copy; status `notSaved`. No refresh starts once quit has begun.

Hosts (`MCPOAuthPolicy`): endpoints must be https; plain http only when the MCP server and that endpoint are both on loopback, which is what the mock uses. A plain-http MCP server off this Mac cannot sign in. A host may be no closer than the MCP server (`MCPOAuthLocality`), or any public server could make Parley probe the local network. The floor is the farthest of the server's addresses; a host being contacted is judged by its closest. Each request checks the resolved address first, and metadata and registration answers check where the connection really went; through a proxy that address is the proxy's, so it is skipped. Numeric oddities such as `0x7f.1`, 0/8, `::` and multicast are refused.

Leaks: OAuth errors are fixed text plus a checked error code, never a server's body or `error_description`, because `MCPError.summary` is saved into conversations. `MCPTokenScrubber` removes the token a request carried from everything that came back, on bytes before an error body is shortened, and by character, because an encoder can write `/` as `\/` or `/`. A static Authorization header means no sign-in and no token; other static headers never go to a provider.

### UI
Settings tab "MCP" (`MCPSettingsView`, a draft with Save and Revert: a live binding would replace a connection on every keystroke; the tool list and approvals are live). Paste-only import with a full review (`MCPImportSheet`). Composer tools button, only with a server configured (`ConversationToolsPopover`, ⇧⌘T). `ToolRoundsView`, `ToolCallRow` and `ToolApprovalCard` in `ToolCallViews.swift`. `ReplyPhase` feeds the status strip's `toolActivity`. The approval card takes `PendingToolApproval.readFromText` for ReAct. The sidebar shows an orange hand while a chat waits for approval. ⌘R on a reply with rounds goes through `AppState.regenerateRequest`, so it asks first like the row does.

Tests: `MCPHardeningTests` hold what the first review found; many of those used to end the process, so a regression shows up as a crashed run. `ToolLoopTests` drive the session with `FakeToolHost`; `MCPIntegrationTests` run the real manager with `tools/mock_mcp_server.py` and `tools/mock_server.py` (whose `mock-tools*` models refuse any dangling tool call). `NativeToolGoldens` holds native request bodies dumped from the code before ReAct: tools, replayed rounds, flattened, `answerNow` at the cap. Never regenerate them. `ReActTests` hold the pure parser with hostile input, fences, the block and bodies; `ReActLoopTests` drive the loop against `mock-react*`, whose servers refuse `tools`, `stop`, roles that do not alternate and an Observation whose fence is not whole, and whose main model keeps streaming past a made-up Observation until the client leaves (`react_disconnects`). `tools/snapshot.sh` covers the Settings tab, import review, popover, approval card and rows, and the same for ReAct. `MCPOAuthPureTests` hold what touches nothing; `MCPOAuthFlowTests` run the real manager, listener and URLSession against the mock's `oauth` behaviors, one for each hostile answer, with a scripted browser that follows the mock's redirects.

Known limits: sign-in has been tested only against `tools/mock_mcp_server.py` with a scripted browser, never against a real provider, a real browser or a real proxy. DNS rebinding is made harder, not impossible: the checks and the connection are separate lookups. The Keychain save after a refresh runs on the broker actor, so a Keychain prompt there holds up that server's token requests until it is answered. LM Studio returned `<server>__<tool>` names unchanged and accepted the replayed tool messages in a live check (Qwen 3.8 27B, two turns, 2026-11-07, against the mock MCP server); other models and parallel calls there are unchecked. The snapshot harness's launch check (PARLEY_SNAPSHOT_LAUNCH_COMMAND) starts a bare command from an app with launchd's PATH. Nothing has been tested against real MCP servers, a modern-only server, or a real Keychain item. A running stdio server keeps tool arguments in its own memory after Lock. macOS 14's `addchdir_np` path has not been run.

## Generation speed and context length

ParleyCore:
- `GenerationStats` (`GenerationStats.swift`, Codable, every field optional) is stored as `Message.stats`: `tokensPerSecond`, `completionTokens`, `timeToFirstToken`, `generationDuration`, `isEstimated`. `TokenUsage.reasoningTokens` holds `completion_tokens_details.reasoning_tokens`. Both are optional, so files written by older versions decode unchanged (tested with literal old JSON, plain and encrypted).
- `ChatDelta.timings` carries llama.cpp's `timings` block (`ServerTimings`).
- `GenerationMeter` measures speed on the client. Every chunk with non-empty reasoning or content counts as one token (the opening `content: ""` chunk does not). The rate is (tokens − 1) / (last token − first token). A server count (`usage.completion_tokens`, `timings.predicted_n`) replaces the chunk count, and `timings.predicted_per_second` replaces the rate. When usage reports `reasoning_tokens` but no reasoning chunk was streamed and the chunk count fits the remaining tokens (OpenAI o-series and similar, not inline `<think>` content), those tokens are subtracted for the rate, since they were generated before the first visible token; the stored `completionTokens` stays the server's total. Time to first token is measured from the request start (so it includes unstreamed reasoning).
- `ChatClient.fetchModelInfo(model:)` (`ModelInfo.swift`) never throws. It parses the existing `GET {base}/models` entry (vLLM `max_model_len`, llama.cpp `meta.n_ctx`/`n_ctx_train`, `context_length`, `top_provider.context_length`, `context_window`, `max_context_length`). Then, only when the base path ends in `/v1` and the host is local (`isLocalHost`) or the list looks like LM Studio or llama.cpp, it tries the native endpoints on the same scheme, host and port: LM Studio `/api/v1/models`, then `/api/v0/models`, llama.cpp `/props` (with `?model=` for router mode), Ollama `/api/ps`. Responses are validated by shape; any top-level `"error"` (LM Studio answers unknown routes with 200 and an error body), non-2xx or non-JSON means "unknown". Each probe has a 5 s timeout. `/slots` is never read.
- `ChatClient.reloadModel(_:contextLength:)` is LM Studio 0.4+ only and state-changing: GET the listing, `POST /api/v1/models/unload` for each loaded instance, then `POST /api/v1/models/load {model, context_length, echo_load_config}` (600 s timeout), then re-read. Loading without unloading first would add a second instance. When the chat model was an instance id (`key:2`), the re-read uses the load response's `instance_id` (else the key), and the returned info's `model` is that new id.
- `ContextBudget` (pure): `limit(info:manual:)` applies the precedence server value > manual value > model maximum; `usage(messages:systemPrompt:inFlightID:liveCompletionTokens:liveIsEstimated:)` starts from the newest reply with server usage (prompt + completion − reported reasoning tokens) and estimates the rest (CJK ≈ 1 token per character, otherwise ≈ 4 characters per token, 768 per image, 4 per message); `contextLength(fromError:)` reads the limit from llama.cpp / vLLM / OpenAI overflow errors.

App:
- `ConversationSession.liveGeneration` is published at most every 0.25 s while streaming; the final stats are written to the reply when streaming ends (completed, stopped or failed).
- `AppState.contextInfo` caches `ModelContextInfo` per provider id, base URL and model (memory only). The probe runs in a task AppState owns, so a cancelled `ChatView` `.task` still gets its result cached and a second caller joins the running probe. A probe that learned nothing is not cached; non-forced retries wait 30 s. `ChatView` probes the selected conversation's provider and model only; after a successful reply, `replyFinished` probes again (forced, past the 30 s wait) when nothing is cached, or (forced) when a not-yet-loaded LM Studio/Ollama model was loaded by it (JIT); an overflow error's size is stored as learned (see Cloudflare below).
- `AppState.reloadModel` refuses while a reload of the same model key on the same base URL is running (claimed before the first await) and waits for a probe in flight first. `reloadStates` keeps `.running`, `.failed` or `.finished(note:)` per key, so the popover can close during a long load; the popover clears a finished or failed state when it closes. A reload that replaced the conversation's instance id switches the conversation's model to the new id.
- `ConversationSession.contextUsage()` caches the history part while streaming (keyed by the in-flight id, message count and system prompt) and adds the live token count, so the strip's re-renders on every 20 Hz message flush do not re-estimate the whole conversation.
- `AppSettings.contextLengthOverrides` stores the user's manual values in UserDefaults, keyed by provider id and model id, or by Strata instance id and model id (see Cloudflare below). `learnedContextLengths` (overflow errors) and `contextInstanceLinks` are keyed the same way.
- `ContextStatusBar` (Views/ContextStatusView.swift) sits below the composer at the bottom-right of the chat: speed, a ring and "used / limit (percent)", orange from 80 %, red from 95 %, "≈" for estimates, "max" before a limit that is only the model's maximum, "Reloading model…" / "Reload failed" from `reloadStates`. All counts use one unit, k = 1024 (`TokenFormat.tokens`). Its popover opens upwards (`arrowEdge: .top`) and shows the details, the manual value and, for LM Studio, "Reload Model…" with an inline confirmation that explains the reload affects every app using the model on that server. The token fields are text drafts parsed on every keystroke (`TokenFormat.parse`), the reload field starts empty with the loaded size as its placeholder, and reloading to the loaded size, while streaming, probing or reloading is disabled. The destructive confirm button has no Return shortcut.

## Strata

[Strata](https://github.com/Niko1221/Strata) (C++ inference engine, Windows/Linux) has two HTTP surfaces; the facts below were read from its source (commit ffa80d73133e, release 0.2.10).

- **Desktop "share on network" port** (`apps/host/server/local-share.mjs`, default 47832, the user's setup): only `GET /v1/models`, `POST /v1/chat/completions` and `/v1/messages`; everything else is a 404 with the bare text `Not found`. With a key, every route wants `Authorization: Bearer` or `x-api-key` (401 `{"error":"Invalid API key"}`). Its list says `owned_by: "strata"`; a native model's `meta` has `{instanceId, gpus, label, aliases}` and no context length (issue #3931), the runtime mode's has `meta.context`. Bodies are capped at 12 MiB (4 MiB in runtime mode); past that the answer is a plain-text HTTP 500 `Request failed`. Chat requests are forwarded to the engine verbatim and its status and body come back unchanged.
- **Engine server** (`serve/server.py`, also PolyStrata): list entries without `owned_by` but with `status.value`, `meta.n_ctx` and `architecture.input_modalities`; `GET /health` without a key: `{max_context, model, images, loaded, service: "strata"}`; `/props` in llama.cpp's shape.

ParleyCore:
- `InferenceServerKind.strata`. `parseModelList` maps `owned_by == ["strata"]` to it, reads `meta.context`, and sets `ModelContextInfo.maxRequestBytes` (12 or 4 MiB); `fetchModelInfo` then returns without native probes. A list that `looksLikeStrataEngine` probes `/health` first (`parseStrataHealth`; its context, images and loaded state apply only when its `model` is the requested one); other local servers try `/health` after the LM Studio probes, so an LM Studio probe sequence is unchanged. `ModelContextInfo.acceptsImages` comes from `/health images` or `input_modalities`. `canSetContextLength` stays false: Strata fixes the context when it starts the model.
- `ChatRequestOptions.serverKind` / `maxRequestBytes` / `disablesThinking` / `reasoningBudgetTokens`. `buildRequestBody` adds `return_progress: true` and `reasoning_budget_tokens` (never with "None") only when `serverKind == .strata` (unknown values are a 400 on Strata, unknown fields can be on strict APIs). "None" sends `reasoning_effort: "none"` to Strata as before; other servers now get their own shape (see "No thinking"). `makeChatRequest` refuses a body over `maxRequestBytes` with a readable `ParleyError.api` before sending (images are re-sent every turn).
- `ChunkParser` reads top-level `prompt_progress` into `ChatDelta.promptProgress` (`PromptProgress`, fraction = (processed − cache) / (total − cache)), `timings.prompt_per_second`, and `usage.prompt_tokens_details.cached_tokens` (`TokenUsage.cachedPromptTokens`). `GenerationMeter` keeps the latest progress until the first token, the finish reason, and stores `finishReason`, `promptTokensRead`, `promptTokensPerSecond` and `cachedPromptTokens` in `GenerationStats` (all optional). tok/s already prefers `timings.predicted_per_second`; time to first token stays client-measured (it includes queueing, a cold model load and the network).
- `ContextBudget.contextLength(fromError:)` also matches Strata's `… the context (N)`; `strataOverflow(fromError:)` parses prompt, context, max tokens and the room it names. Max Tokens is always sent as set: with Strata's default `fit_max_tokens` it shortens an oversized cap to the exact room left, which beats any client-side estimate; with it off, the 400 names the room ("at most R here") and the error says to lower Max Tokens to it. `usage` now subtracts an estimate of a counted reply's reasoning text when the server reports no `reasoning_tokens` (capped at its completion tokens), for every server.
- New persisted fields are all optional: `ConversationSettings.disablesThinking` / `reasoningBudgetTokens` (a separate field rather than a `ReasoningEffort` case, so an older Parley still decodes the file; "None (no thinking)" in the picker), `TokenUsage.cachedPromptTokens`, and the `GenerationStats` fields above.

App:
- `ConversationSession.serverInfo` (set in `AppState.register`, which all four session constructors use) looks up the cached `ModelContextInfo`; `startReply` fills the options (server kind, `maxRequestBytes`) from it. Before the probe has finished the request is a plain OpenAI one.
- `AppState.replyFinished` fills an unknown limit from Strata's overflow error, and records `acceptsImages = false` after Strata's "started without the vision encoder" refusal (memory only; `store` keeps it across probes, a later successful reply with images clears it).
- `ErrorPresentation.strataPresentation` maps Strata's exact texts (overflow, vision, model not ready / not loaded / wrong id, paused, engine starting or stopped, busy: queue wait expired / admission full / batch slots, draining, GPU memory taken) for both the `HTTP n:` and the mid-stream `API error:` forms; only the bare 500 `Request failed`, the 502 `fetch failed` (Node's generic text), the key hint and the port hint need `serverKind`.
- `MessageRow` shows `WaitingIndicator` before the first token (prompt progress, else elapsed seconds; for Strata after 10 s without progress a "may be loading the model or reading a long prompt" line; the live share port never sends progress, so there it is elapsed seconds and that line) and `finishNote` for `finish_reason == "length"`: with the conversation's Max Tokens reached it suggests raising it (or, when only thinking came back, lowering the effort / a budget); with no cap or fewer completion tokens than the cap the context ran out (Strata shortened the cap), so it suggests a new chat, fork or roll back. Its `==` includes `serverKind`, `promptProgress` and `maxTokens`. Errors whose retry can only fail the same way (`ErrorPresentation.retryable == false`: the pre-send "request too large" refusal, parsed by `ChatClient.requestTooLarge(in:)`) show no Retry. The status strip shows "Reading prompt N%", the popover a Prompt row (read, rate, cached) and, for Strata, that the context is fixed in Strata's setup. The composer warns (does not block) when a model known not to read images would get one: from the draft ("remove the image") or, since every request re-sends them, from earlier user messages ("turn Pictures on / fork before the first image"); or when the conversation's images exceed `maxRequestBytes`. The conversation settings offer "None (no thinking)" for every server and a thinking budget only for Strata (or when already set).
- Mock: `strata-share` and `strata-engine` emulate these shapes, Strata's SSE (`: keep-alive`, `prompt_progress` on `strata-engine` only (the live share port sends none; `MOCK_STRATA_PROGRESS=1` turns it on there), `reasoning_content`, final chunk with usage and timings), its fit logic against an 8192-token context (`strata-nofit` answers the 400), and its refusals. Like the real share it lists ready models only (`strata-loading` is missing from `/v1/models` but answers 400 "This model is not ready."), and checks path, then key, then the 12 MiB body cap. The snapshot harness (`PARLEY_SNAPSHOT_STRATA_URL`, started by `tools/snapshot.sh`) adds a Strata chat, its context popover and settings, prompt reading, a refused image, and (light only) a request refused before sending as too large.
- Not done on purpose: `/v1/messages` and `/v1/responses` (Parley stays on chat completions), `/slots`, the `X-Strata-Client` header (only the runtime path reads it), and any load/unload call.

## No thinking ("None")

The reasoning picker offers Not sent (default, unchanged), "None (no thinking)", Low, Medium, High for every server. "None" is still stored as `ConversationSettings.disablesThinking`. Sources were read, not run (llama.cpp 149f564, vLLM d3fb716, Ollama e9fde36, Strata ffa80d7, LM Studio docs and changelogs, the OpenAI and OpenRouter OpenAPI specs, Gemini's OpenAI-compatibility page, all 2026-11-02 to -04).

`ChatClient.thinkingOffFields(for:)`, on `POST /v1/chat/completions`:

| Server kind | Sent | Status |
|---|---|---|
| Strata | `reasoning_effort: "none"` | confirmed (live; `serve/frontend.py`) |
| llama.cpp | `chat_template_kwargs: {enable_thinking: false}` | confirmed (`server-common.cpp`; since b5780; `"none"` only from b10121) |
| vLLM | `chat_template_kwargs: {enable_thinking: false}` | confirmed (`chat_completion/protocol.py`; `"none"` is a 400 up to v0.17.1 and on gpt-oss, so it is not sent) |
| Ollama | `reasoning_effort: "none"` | confirmed (`openai/openai.go`, `think=false`, v0.12.4+; it does not read `chat_template_kwargs`) |
| LM Studio | `reasoning_effort: "none"` | verified live 2026-11-04 (Qwen 3.8 27B, `capabilities.reasoning` off/on, default on): no reasoning, `reasoning_tokens` 0. The values are not documented (field since 0.4.8); `chat_template_kwargs` is ignored (bug tracker #1990) |
| hosted / unknown | `reasoning_effort: "none"` | best effort: OpenAI gpt-5.1+, OpenRouter, Gemini 2.5 Flash document it; original gpt-5, GPT-6 Astra/6.1 Sol, Gemini 2.5 Pro / 3 and OpenRouter "mandatory" models refuse it |

Whether thinking really stops depends on the model's chat template on llama.cpp and vLLM (Qwen3 reads `enable_thinking`; gpt-oss does not). The thinking budget stays Strata-only: no other server has a confirmed per-request equivalent.

- `buildRequestBody`: with `disablesThinking && !omitsThinkingOff` it removes `reasoning_effort` and adds the fields above. With "Not sent" or an effort, every server kind's body is byte-identical to before (`ThinkingOffTests` compares sorted-key JSON dumped from the old code).
- Possible refusal (`ThinkingOffSupport.isRejection`): HTTP 400/422, the field was sent, the server is not known to be Strata (where `"none"` is verified, so its 400s are about something else), it is not an overflow (`ContextBudget.contextLength(fromError:)`, "context length/window"), and the body names the field or what it controls: `reasoning_effort`/`reasoning.effort`/"reasoning"/"thinking" for `reasoning_effort` (OpenAI's `param`, Ollama's `invalid reasoning value`, Gemini's "Thinking can't be disabled"), `chat_template_kwargs`/`enable_thinking`/"thinking" for the template field. Any other 400 (e.g. `mock-error`'s "mock bad request") is not retried.
- `streamChat` then sends the request once more with `omitsThinkingOff` (Strata's budget rule still follows `disablesThinking`). Only if that retry is answered with a 2xx is it a refusal: `runStream` yields `ChatDelta(thinkingOffRejected: true)` before reading the stream. If the retry is refused too, the field was not the cause: the first answer's `ParleyError.http` is thrown, nothing is yielded, nothing remembered. The `stream_options` check runs before this one (a body that echoes the whole request could blame `stream_options` first; accepted, it costs one request or the usage line for one launch).
- `AppState.thinkingOffRejections` (`[ContextKey: Set<String>]`, memory only, per AppState instance, `resetThinkingOffRejections()`) remembers which fields (`thinkingOffFields` keys) each provider, base URL and model refused. After the probe wait the session leaves the fields out only when the ones this server kind would get overlap a refused set (a refusal of `reasoning_effort` while the kind was unknown does not stop vLLM from getting `chat_template_kwargs` later), and marks the reply once the server has answered with a 2xx. There is no process-wide registry.
- Notes, persisted on the reply (optional, so old files decode and an older Parley ignores them): `Message.thinkingOffNotAccepted` (refused: the reply used the server's default thinking), `Message.thinkingOffIgnored` (sent, but non-blank reasoning came back: `reasoning_content`, `reasoning` or `<think>`; set in `endStreaming`) and `Message.thinkingOffServerKind` (raw value of the kind the ignored request was shaped for; a `String`, so a later kind cannot break decoding). `MessageRow.thinkingOffNote` words them, adding for LM Studio that it may offer a thinking switch in the model's settings (unverified wording), and for llama.cpp/vLLM that the chat template may not support it; the hint follows the stored kind, not the conversation's current server. A reply whose nearest earlier reply has the same note gets a one-line short form (full text in the help tag; `repeatsThinkingOffNotes`). A reply that failed before any text arrived shows no note. Neither note ever says thinking was off; the icon is `info.circle`, not the thinking section's brain.
- Probe race: the request shape depends on `serverKind`, which comes from AppState's probe. When the conversation uses "None" or a thinking budget and nothing is known yet, the stream task first calls `AppState.awaitServerInfo` (starts the probe synchronously, then polls every 20 ms up to `serverInfoWaitTimeout`, 4 s, for "None", or `serverInfoBudgetWaitTimeout`, `probeTimeout` + 1.5 s, for a budget, which is dropped without the kind; instance properties). Polling, rather than awaiting the probe task, lets Stop end the wait at once; the message is then finalized and no chat request is sent. The meter restarts after the wait, so time to first token is the server's. Other settings never wait.
- Snapshot harness: `conversation-settings-none`, `strata-conversation-settings-none` and `thinking-off-notes` (one ignored by LM Studio, one refused, one refused again in the short form), light and dark.

## Cloudflare and shared Strata routes

The user reaches one Strata over Tailscale (`http://100.x:47832/v1`) and over a Cloudflare Tunnel (`https://<host>/v1`, same key). Live captures showed: the tunnel adds `server: cloudflare`, `cf-ray`, `cf-cache-status`, `nel`/`report-to` to every answer (the origin's JSON errors included), streams SSE incrementally, and serves plain http too (no redirect).

ParleyCore (`EdgeErrors.swift`):
- `ResponseText.errorBody(status:response:data:)` builds every `ParleyError.http` body (`fetchModels`, `runStream`, `requestJSON`). A Cloudflare-generated answer becomes `CloudflareError.summary` (`Cloudflare error 1033: Cloudflare Tunnel error · Ray ID …`, `Cloudflare challenge: …`, `Cloudflare Access sign-in at <host> (redirect not followed)`); another refused 3xx `Redirect to <scheme://host/path> (not followed)` (no query); any other HTML page its title (or first heading, else "HTML page"); everything else the first 2000 characters as before. The stored text stays `HTTP n: …`, so old files, `splitHTTP` and Equatable are unchanged. `runStream` reads up to 64 KiB of an error body (Cloudflare pages put their code after several KB of CSS) before reducing it.
- `CloudflareError.detect` never trusts the headers alone: it needs a 520–530 status, `cf-mitigated: challenge`, Cloudflare's error-page markers (`cf-error-details`, `cf-wrapper`, `cf-error-code`, "Cloudflare Ray ID"; not `/cdn-cgi/` or `challenge-platform`, which Cloudflare's JS detection injects into the origin's ordinary pages), a challenge interstitial (`cf_chl_opt` or the "Just a moment" title on a 403/503), an empty 502/504 with Cloudflare's headers (cloudflared cannot reach the origin), or a body that is exactly `error code: NNNN` (live only with Cloudflare's headers; a stored body without them), or a `Location` on `*.cloudflareaccess.com`. A JSON body is always the origin's, also when it quotes markup (`errorBody`, `isHTMLPage` check JSON before HTML). `Kind`: timeout (524), tunnelDown (530, 1033, tunnel wording), originUnreachable (520–523, 502, 504), originTLS (525/526), challenge (challenge, 1006–1012, 1020), rateLimited (1015, 429), access, other. `CloudflareError.parse(status:body:)` reads the summary back and also raw pages stored by older versions.
- Streaming: once a 2xx arrived, a non-cancel `URLError` while reading becomes `ParleyError.api(StreamInterruption.message(…))` ("The connection closed before the reply finished[ (through Cloudflare)]: <URLError text>"), and an SSE body that ends after yielding deltas with neither a `finish_reason` nor `[DONE]` throws the same without the underlying text. `withPathHint` leaves it alone.
- `ModelContextInfo.serverInstanceID` = Strata's `meta.instanceId` (`parseModelList`, which also finds an entry by `meta.aliases`); `merge` carries it. `ContextLimitSource.learned`; `ContextBudget.limit(info:manual:learned:)` = server > manual > learned > model maximum; the app keeps "the newer of manual and learned wins" by clearing a manual value that a later overflow contradicts.

App:
- `AppState.contextInstanceID` (`AppSettings.linkedInstanceID` at the provider's current base URL, else this launch's probe), `manualContextLength` / `setManualContextLength` / `learnedContextLength` / `contextLimit(provider:model:)`. Values live under `strata:<instanceId>|<model>` when an instance is known, else `<providerID>|<model>`. A link (`contextInstanceLinks`, `<providerID>|<model>` → instance id + normalized base URL) only counts while the provider still has that base URL. `store` calls `AppSettings.linkInstance` (and `unlinkInstance` when a probe finds another kind of server there; an empty probe keeps the link). `linkInstance` moves values found under the provider key (entered before the instance was known) to the instance key (an existing instance value wins: no timestamps are kept, and a provider-key value can only exist from before that provider's first probe at its address). When the same provider at the same address sees a new id (Strata restarted the model; live, the id did change for the same model), the user's value moves to the new id, the learned one does not (the restart may have changed the context; the next overflow names it), and every other link to the old id follows to the new one, so a value cleared on one route cannot come back from another. A provider at a new address carries nothing over. Instance values no link points to are removed (also after `unlinkInstance`). Setting or clearing a manual value removes the provider-key copy too. `replyFinished` stores any overflow size (`ContextBudget.contextLength(fromError:)`) as learned, always replacing the previous one, and clears a manual value that differs from it (the newer value wins; a value typed afterwards beats the learned one). `store` drops a learned value when the server reports a different loaded length, and a successful `reloadModel` drops it too (LM Studio), so it cannot outlive a reload and a later unload.
- `ErrorPresentation.make(…, partialReply:)`: Cloudflare kinds before the Strata texts and the status switch (copy is generic and names Strata only when `serverKind == .strata`), redirects (http→https on the same host suggests the https base URL), interruptions ("The text received so far is kept"), and stored HTML reduced via `sanitizedBody`. `displayText` feeds Details and the tooltip, `connectionTestText` Settings' Test Connection. The context popover shows the learned size (source "learned from Strata's error", a "Last error" row when another value wins) and says the value is shared across routes.
- Timeouts: unchanged. Parley's 600 s is an idle timeout between bytes; Cloudflare answers 524 after 100 s without the first byte. Strata sends `: keep-alive` at least every 10 s while queued or reading the prompt, so only a wait before the very first byte (a cold model load) hits 524, which now says so. Parley never reads or acts on `nel`/`report-to` and sends only its own requests to the configured host. Live check (best effort): two 401s carrying `nel`/`report-to` through the tunnel, then 80 s of watching sockets and the process's network log, showed no connection to the report host; CFNetwork and Network.framework contain no NEL/Report-To strings (they do contain HSTS and Alt-Svc). macOS networking does not appear to implement NEL.
- Mock: `/cf/…` adds Cloudflare's headers to the normal answer; `/cf-520/` … `/cf-530/`, `/cf-1033/`, `/cf-challenge/`, `/cf-block/`, `/cf-1015/`, `/cf-access/`, `/cf-https/` answer as Cloudflare's edge (any flavor); models `mock-drop` (connection reset mid-body) and `mock-cut` (clean end without finish_reason or [DONE]). The snapshot harness adds `strata-cloudflare-errors` (light) and a learned value in the Strata popover.
- Live: `meta.instanceId` changed between two days for the same model (`iq3_s`), handled as a restart above. The Cloudflare route ran over HTTP/3; a mid-stream drop over QUIC was not reproduced live (any `URLError` after the 200 counts as a dropped reply).
