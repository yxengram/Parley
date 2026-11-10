import Foundation
import Testing
@testable import ParleyCore

// Fixtures for the offline reader (Reader/ParleyReader.html), written by Parley's own encoder so the
// reader is tested against real files. Does nothing unless PARLEY_READER_FIXTURES names an empty
// or missing directory; tools/test_reader.sh sets it to a temporary one.

/// The passwords the reader tests type. The second is NFD on purpose: Parley normalises to NFC,
/// so the reader must too.
enum ReaderFixturePasswords {
    static let plain = "correct horse"
    static let composed = "caf\u{E9} \u{5BC6}\u{7801}"          // "café 密码", é precomposed
    static let decomposed = "cafe\u{301} \u{5BC6}\u{7801}"      // the same, é as e + combining accent
}

@Test func writeReaderFixtures() throws {
    guard let path = ProcessInfo.processInfo.environment["PARLEY_READER_FIXTURES"], !path.isEmpty else { return }
    let dir = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let base = Date(timeIntervalSince1970: 1_793_000_000)  // whole seconds: .iso8601 drops fractions
    func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    func save(_ name: String, _ data: Data) throws {
        try data.write(to: dir.appendingPathComponent(name))
    }

    // 1x1 opaque orange PNG.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4f9AAAAQAAc0Ckm8AAAAASUVORK5CYII=")!

    var settings = ConversationSettings(providerID: UUID(), model: "qwen3-14b-instruct",
                                        systemPrompt: "You are a careful assistant.", temperature: 0.4)
    settings.mcpServerIDs = [UUID()]

    let user1 = Message(
        role: .user,
        content: "Why does this crash? <img src=x onerror=\"window.__pwned=1\"> **not bold in a note**",
        attachments: [
            Attachment(kind: .image, filename: "screen \"shot\".png", mimeType: "image/png", data: png),
            Attachment(kind: .text, filename: "crash-log.txt", mimeType: "text/plain",
                       text: "Fatal error: Unexpectedly found nil\n<script>window.__pwned=2</script>"),
        ],
        createdAt: at(0)
    )
    let markdown = """
    ## Diagnosis

    The crash comes from force-unwrapping `URL(string:)` when the path has a space.

    - `URL(string:)` returns `nil` for spaces
      - nested *detail*
    1. first
    2) second
    - [x] done
    - [ ] open

    > Quoted **advice**

    | Call | Result |
    | --- | --- |
    | `URL(string:)` | nil |

    ```swift
    let url = URL(fileURLWithPath: path) // <b>not markup</b>
    ```

    ---

    See [Apple's docs](https://developer.apple.com/documentation/foundation/url), [a trap](javascript:window.__pwned=3) and ![remote](https://example.com/track.png). 中文段落：这是一个**测试**。
    """
    let reply1 = Message(
        role: .assistant,
        content: markdown,
        reasoning: "The log shows a force unwrap.\n\n- check the path\n- `guard let`",
        reasoningDuration: 7.4,
        createdAt: at(1),
        model: "qwen3-14b-instruct",
        usage: TokenUsage(promptTokens: 912, completionTokens: 188, totalTokens: 1100, reasoningTokens: 40),
        stats: GenerationStats(tokensPerSecond: 44.8, completionTokens: 188, timeToFirstToken: 1.12,
                               generationDuration: 4.2, isEstimated: false, finishReason: "stop",
                               promptTokensRead: 900, promptTokensPerSecond: 812.5, cachedPromptTokens: 12)
    )

    var toolReply = Message(
        role: .assistant,
        content: "The folder has **two** files.",
        createdAt: at(3),
        model: "qwen3-14b-instruct",
        usage: TokenUsage(promptTokens: 1400, completionTokens: 30, totalTokens: 1430)
    )
    toolReply.toolRounds = [
        ToolRound(
            content: "Let me look.",
            reasoning: "Need the listing.",
            reasoningDuration: 1.5,
            calls: [
                ToolCallRecord(id: "call_1", name: "list_files", arguments: #"{"path":"~/Projects"}"#,
                               serverName: "Files", toolName: "list_files", startedAt: at(2),
                               result: ToolCallResult(status: .completed, text: "a.txt\nb.txt", duration: 0.25)),
                ToolCallRecord(id: "call_2", name: "read_file", arguments: #"{"path":"secret"}"#,
                               serverName: "Files", toolName: "read_file", startedAt: at(2),
                               result: ToolCallResult(status: .denied, text: "The user denied this call.")),
                ToolCallRecord(id: "call_3", name: "fetch", arguments: "{not json",
                               result: ToolCallResult(status: .toolError, text: "Error: bad arguments",
                                                      originalCharacters: 90_000, omitted: ["image/png, 230 KB"])),
                ToolCallRecord(id: "call_4", name: "slow", arguments: "{}", serverName: "Files", startedAt: at(2)),
            ],
            usage: TokenUsage(promptTokens: 1200, completionTokens: 20, totalTokens: 1220),
            stats: GenerationStats(tokensPerSecond: 30, completionTokens: 20, timeToFirstToken: 0.5)
        ),
    ]
    toolReply.toolNotes = [ToolNote(kind: ToolNote.roundLimit), ToolNote(kind: "futureKind", detail: "A note from a later version.")]
    toolReply.toolDefinitionTokens = 310

    var reactReply = Message(role: .assistant, content: "Done.", createdAt: at(5), model: "qwen3-14b-instruct")
    reactReply.reactThought = "I should answer directly."
    reactReply.thinkingOffIgnored = true
    reactReply.thinkingOffServerKind = "lmstudio"

    let failed = Message(role: .assistant, content: "Partial ans", createdAt: at(6), model: "qwen3-14b-instruct",
                         isComplete: false, error: #"HTTP 503: {"error":"Model is loading."}"#)

    let conversation = Conversation(
        title: "Crash when loading config files <b>",
        createdAt: at(-10),
        updatedAt: at(6),
        settings: settings,
        messages: [
            user1, reply1,
            Message(role: .user, content: "List my project folder.", createdAt: at(2)),
            toolReply,
            Message(role: .user, content: "Thanks — 谢谢！", createdAt: at(4)),
            reactReply,
            failed,
        ],
        forkedFrom: ForkOrigin(conversationID: UUID(), messageID: UUID())
    )

    try save("plain.json", ConversationFile.encode(conversation, encryption: nil))
    // What the reader must show for the encrypted files: the same conversation.
    try save("expected.json", ConversationFile.makeEncoder(pretty: true).encode(conversation))

    let fast = try ConversationCrypto.newKey(password: ReaderFixturePasswords.plain, iterations: 1000)
    try save("encrypted.json", ConversationFile.encode(conversation, encryption: fast))

    // Default iterations, so the reader's timing is real; password typed with a decomposed é.
    let slow = try ConversationCrypto.newKey(password: ReaderFixturePasswords.composed)
    try save("encrypted-600k.json", ConversationFile.encode(conversation, encryption: slow))

    // Header changed after encryption: authentication must fail, like a wrong password.
    let sealed = try ConversationFile.encode(conversation, encryption: fast)
    var header = try #require(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])
    header["id"] = UUID().uuidString
    try save("tampered.json", JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys]))

    // A plain file from an older version: optional fields absent.
    let minimal = Conversation(title: "Old file", createdAt: at(0), updatedAt: at(0),
                               messages: [Message(role: .user, content: "Hi", createdAt: at(0))])
    try save("minimal.json", ConversationFile.encode(minimal, encryption: nil))

    try save("not-parley.json", Data(#"{"hello":"world"}"#.utf8))
    try save("future.json", Data(#"{"format":"parley.conversation","version":2,"encrypted":false}"#.utf8))

    // Sanity: Parley itself reads them back.
    let readBack = try ConversationFile.decodeEncrypted(sealed, password: ReaderFixturePasswords.plain).0
    #expect(readBack == conversation)
}
