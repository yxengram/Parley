import Foundation

// Tool calling on the chat side: what a reply stores about its tool rounds, the text the model
// receives for each outcome, and how streamed tool_calls fragments fold into whole calls. Nothing
// here talks to an MCP server (see MCP/).

/// One tool round inside an assistant reply: what the model wrote before asking, and the calls
/// with their results. A call and its result live in one Message, so rollback and fork stay atomic.
/// Optional fields and Strings rather than enums, like the other persisted notes: a value a later
/// version adds must not stop this version decoding the file.
public struct ToolRound: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var content: String
    public var reasoning: String?
    public var reasoningDuration: Double?
    public var calls: [ToolCallRecord]
    /// The usage of the request that produced this round (its prompt includes earlier rounds).
    public var usage: TokenUsage?
    public var stats: GenerationStats?

    public init(id: UUID = UUID(), content: String, reasoning: String? = nil, reasoningDuration: Double? = nil,
                calls: [ToolCallRecord], usage: TokenUsage? = nil, stats: GenerationStats? = nil) {
        self.id = id
        self.content = content
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.calls = calls
        self.usage = usage
        self.stats = stats
    }
}

public struct ToolCallRecord: Codable, Identifiable, Hashable, Sendable {
    /// tool_call_id: the server's, or a synthesized "call_xxxxxxxx" when blank or repeated in this reply.
    public var id: String
    /// The function name as sent to the model. Replayed unchanged, whatever the config says later.
    public var name: String
    /// The model's raw text, for display. Replay uses `replayArguments`.
    public var arguments: String
    public var serverID: UUID?
    public var serverName: String?
    /// The MCP tool name (nil when the model named a tool that does not exist).
    public var toolName: String?
    /// Set and saved just before tools/call goes out: a crash after this may have run the tool.
    public var startedAt: Date?
    /// nil = unresolved (in flight, or the app died). Replay synthesizes a result for it.
    public var result: ToolCallResult?

    public init(id: String, name: String, arguments: String, serverID: UUID? = nil, serverName: String? = nil,
                toolName: String? = nil, startedAt: Date? = nil, result: ToolCallResult? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.serverID = serverID
        self.serverName = serverName
        self.toolName = toolName
        self.startedAt = startedAt
        self.result = result
    }
}

public struct ToolCallResult: Codable, Hashable, Sendable {
    /// ToolCallStatus raw value; a String for the reason above.
    public var status: String
    /// Exactly what the model receives as the tool message, truncation note included.
    public var text: String
    public var duration: Double?
    /// Character count before truncation, when truncated.
    public var originalCharacters: Int?
    /// What was left out, e.g. "image/png, 230 KB".
    public var omitted: [String]?

    /// `status` as a value this version knows.
    public var callStatus: ToolCallStatus? { ToolCallStatus(rawValue: status) }

    public init(status: ToolCallStatus, text: String, duration: Double? = nil, originalCharacters: Int? = nil, omitted: [String]? = nil) {
        self.status = status.rawValue
        self.text = text
        self.duration = duration
        self.originalCharacters = originalCharacters
        self.omitted = omitted
    }
}

public enum ToolCallStatus: String, Sendable {
    case completed      // tool ran, isError false
    case toolError      // tool ran, isError true
    case failed         // JSON-RPC or transport failure
    case timedOut
    case denied         // the user chose Deny
    case cancelled      // Stop, Lock, close, quit
    case notCalled      // malformed arguments or unknown tool
}

/// A note under a reply. `kind` is a String; unknown kinds show `detail`.
public struct ToolNote: Codable, Hashable, Sendable {
    public var kind: String
    public var detail: String?

    public static let toolsNotAccepted = "toolsNotAccepted", toolsNotOffered = "toolsNotOffered",
        serverUnavailable = "serverUnavailable", roundLimit = "roundLimit",
        callsNotRun = "callsNotRun", emptyAfterTools = "emptyAfterTools", nativeCallsIgnored = "nativeCallsIgnored"
    /// Its `detail`. It sits on replies that ended well, and on replies whose text call ran.
    public static let nativeCallsIgnoredText = "The model sent native tool calls. ReAct runs only calls written as text, so those were not run."

    public init(kind: String, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// One OpenAI function definition.
public struct ChatTool: Sendable, Hashable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue

    public init(name: String, description: String? = nil, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// One entry of a chunk's `tool_calls`. Every field may be missing, depending on the server.
public struct ToolCallDelta: Sendable, Equatable {
    public var index: Int?
    public var id: String?
    public var name: String?
    public var arguments: String?

    public init(index: Int? = nil, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The server turned the request down because of its tools, and accepted it without them.
public struct ToolsRefusal: Sendable, Equatable {
    public enum Kind: Sendable {
        /// This server or model has no tool support: remembered per provider and model.
        case unsupported
        /// It could not take these definitions: one server's bad schema, not remembered.
        case definitions
    }
    public var kind: Kind
    /// The server's own text.
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum ToolArguments {
    /// Blank or `null` → [:] (a zero-argument call). A JSON object → its dictionary. Else nil.
    public static func parse(_ raw: String) -> [String: JSONValue]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [:] }
        guard case .object(let object)? = JSONValue(jsonText: trimmed) else { return nil }
        return object
    }

    /// Why `raw` is not an arguments object, for the text the model receives.
    public static func problem(_ raw: String) -> String {
        JSONValue(jsonText: raw) == nil ? "not valid JSON" : "not an object"
    }
}

/// The fixed strings the model sees for each outcome that has no text of its own.
public enum ToolResultText {
    public static let notRun = "The tool was not run because the user stopped the reply."
    public static let interrupted = "The call was interrupted. The tool may or may not have completed."
    public static let denied = "The user denied this tool call."
    public static let crashed = "The server stopped while running this tool. It may have partly run."
    public static let empty = "(The tool returned no output.)"

    public static func malformed(reason: String, raw: String) -> String {
        "The tool was not called: its arguments were not a valid JSON object (\(reason)). What you sent: \(raw.prefix(2000))"
    }

    public static func notCalled(_ reason: String) -> String {
        "The tool was not called: \(reason)"
    }

    /// The user switched the server or the tool off while this reply was running.
    public static let turnedOff = "The tool was not called: it was turned off while this reply was running."

    /// Closes a request that has to go out without `tools` while the reply is still open. Ending on
    /// an assistant turn would have llama.cpp and Ollama continue that turn instead of answering.
    public static let answerNow = "Answer now from the tool results above. No more tools are available."

    /// ReAct replay of a reply that ended in a round, with a next user turn after it. Sent, not
    /// stored: the Observation is a user turn, and strict templates refuse two in a row.
    public static let noAnswer = "(This reply ended without an answer.)"

    public static func unknownTool(_ name: String) -> String {
        "The tool was not called: no tool named \(name) is available."
    }

    public static func timedOut(seconds: Double) -> String {
        "The tool did not finish within \(Int(seconds.rounded())) seconds and was cancelled. It may have partly run."
    }

    public static func failed(_ message: String) -> String {
        "The tool call failed: \(message)"
    }
}

extension Message {
    /// Every visible text of the reply, rounds first. What Copy copies.
    public var visibleText: String {
        guard let rounds = toolRounds, !rounds.isEmpty else { return content }
        return (rounds.map(\.content) + [content])
            .filter { !Self.isBlank($0) }
            .joined(separator: "\n\n")
    }

    /// Newest stats of the reply: `stats`, else the last round's.
    public var latestStats: GenerationStats? {
        stats ?? toolRounds?.last(where: { $0.stats != nil })?.stats
    }

    /// The reply as plain assistant text, for a request without `tools`: structured tool messages
    /// cannot go out then (a server without tools may refuse them or drop them). Results are kept,
    /// because the model needs the facts.
    public var flattenedForRequest: String {
        var parts: [String] = []
        for round in toolRounds ?? [] {
            if !Self.isBlank(round.content) { parts.append(round.content) }
            for call in round.calls {
                let label = [call.serverName, call.toolName ?? call.name].compactMap { $0 }.joined(separator: ".")
                parts.append("[Earlier tool call: \(label)(\(call.replayArguments))]")
                parts.append("[Result]\n\(call.replayResult)")
            }
        }
        if !Self.isBlank(content) { parts.append(content) }
        return parts.joined(separator: "\n\n")
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ToolCallRecord {
    /// The raw text when it parses to a JSON object, else "{}".
    public var replayArguments: String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", ToolArguments.parse(trimmed) != nil else { return "{}" }
        return trimmed
    }

    /// `result.text`, or the fixed text for an unresolved call. Never empty, never nil.
    public var replayResult: String {
        if let text = result?.text, !text.isEmpty { return text }
        if result != nil { return ToolResultText.empty }
        return startedAt == nil ? ToolResultText.notRun : ToolResultText.interrupted
    }
}

// MARK: - Streamed tool calls

/// Folds `tool_calls` fragments into whole calls. The servers differ a lot:
///  - LM Studio, Strata: a first fragment with id and name, then fragments with index and arguments.
///  - llama.cpp: the first fragment may have no `arguments` key, or already carry some. A changed
///    id or name resends the id and the whole name.
///  - vLLM: name and arguments fragments in one array, beside `content`.
///  - Ollama: every call whole, in one chunk.
public struct ToolCallAccumulator: Sendable, Equatable {
    private struct Slot: Sendable, Equatable {
        var index: Int?
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var slots: [Slot] = []

    public init() {}

    public var isEmpty: Bool { slots.isEmpty }

    public mutating func apply(_ delta: ToolCallDelta) {
        let position = slotPosition(for: delta)
        var slot = slots[position]
        let id = delta.id ?? ""
        let name = delta.name ?? ""
        if !name.isEmpty {
            if !id.isEmpty || slot.name.isEmpty || name == slot.name {
                slot.name = name
            } else {
                slot.name += name
            }
        }
        if !id.isEmpty { slot.id = id }
        if let arguments = delta.arguments { slot.arguments += arguments }
        slots[position] = slot
    }

    private mutating func slotPosition(for delta: ToolCallDelta) -> Int {
        let id = delta.id ?? ""
        let name = delta.name ?? ""
        if let index = delta.index {
            if let position = slots.lastIndex(where: { $0.index == index }) {
                let slot = slots[position]
                // Some servers number every parallel call 0: a new id once this call has its
                // arguments can only be another call. So can a new name without any id. A new id
                // before arguments stays here: llama.cpp resends the id and the whole name when
                // either changes, as long as the new name still starts with the old one.
                let sameCall: Bool
                if !id.isEmpty, !slot.id.isEmpty, slot.id != id {
                    sameCall = slot.arguments.isEmpty && name.hasPrefix(slot.name)
                } else if id.isEmpty, !name.isEmpty, name != slot.name {
                    sameCall = slot.arguments.isEmpty
                } else {
                    sameCall = true
                }
                if sameCall { return position }
            }
        } else if id.isEmpty, !slots.isEmpty {
            // A fragment of the last call, unless a name after its arguments starts another.
            if name.isEmpty || slots[slots.count - 1].arguments.isEmpty { return slots.count - 1 }
        } else if !id.isEmpty, let position = slots.lastIndex(where: { $0.id == id }) {
            return position
        }
        slots.append(Slot(index: delta.index))
        return slots.count - 1
    }

    /// The calls in index order, without nameless ones. A blank id, or one already used in this
    /// reply (`existingIDs`) or in this round, is replaced with "call_" + 8 hex: a repeated id
    /// would attach a tool result to the wrong call.
    public func finalCalls(existingIDs: Set<String> = []) -> [ToolCallRecord] {
        var used = existingIDs
        let ordered = slots.enumerated().sorted { a, b in
            (a.element.index ?? a.offset, a.offset) < (b.element.index ?? b.offset, b.offset)
        }
        var out: [ToolCallRecord] = []
        for slot in ordered.map(\.element) where !slot.name.isEmpty {
            var id = slot.id
            if id.isEmpty || used.contains(id) {
                repeat {
                    id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
                } while used.contains(id)
            }
            used.insert(id)
            out.append(ToolCallRecord(id: id, name: slot.name, arguments: slot.arguments))
        }
        return out
    }
}
