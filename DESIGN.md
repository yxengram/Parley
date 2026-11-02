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
3. No agent or tool features. The app does support image and text-file attachments.
4. Thinking/reasoning is supported: stream it, show it collapsibly, and show its duration.
5. Settings hold a default conversation directory, and each new conversation can pick its own directory. Each conversation is saved as one JSON file.
6. One click copies any user or assistant message.
7. Roll back to any past message.
8. Fork from any message.
9. **Privacy:** nothing leaves the machine except the configured API calls.
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
The keychain must never be synced, so `kSecAttrSynchronizable` stays false (the default).

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
- Body fields: `model`, `stream: true`, `messages`, and optionally `temperature`, `max_tokens`, `reasoning_effort` (only when non-nil).
- If `systemPrompt` is not blank, it is sent first with role `system`.
- User messages with no images send content as a string. Text attachments are appended as ``"\n\n<file name=\"NAME\">\nTEXT\n</file>"``.
- User messages with images send content as an array: `[{"type":"text","text":...}, {"type":"image_url","image_url":{"url":"data:<mime>;base64,<b64>"}}...]`.
- Assistant messages send only `content`. **Never** send `reasoning`.
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
  - A warning when the base URL is http and the host is not local: "Traffic is unencrypted."
  - A default directory chooser.
  - A privacy note: "Parley only contacts the API endpoints you configure. No telemetry."
- **Markdown rendering:**
  - The app must never fetch remote URLs, so do not use AsyncImage for model output.
  - Implement a small block renderer:
    - Split on fenced code blocks. Code renders monospaced in a rounded background with a per-block copy button.
    - Other paragraphs render with `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`.
    - Headings (`#`) are bold and larger. List lines keep their bullets.
  - `.textSelection(.enabled)`.
  - Links are shown but only opened by the user's click.

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
