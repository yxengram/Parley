import Foundation

// Shared data model. Everything here is Codable and is what ends up inside a
// conversation JSON file (encrypted or not). Keep it free of UI types.

public enum Role: String, Codable, Sendable, Hashable {
    case system
    case user
    case assistant
}

public struct Attachment: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case image
        case text
    }

    public var id: UUID
    public var kind: Kind
    public var filename: String
    /// e.g. "image/jpeg", "image/png", "text/plain".
    public var mimeType: String
    /// Image bytes (already downscaled). JSONEncoder stores Data as base64.
    public var data: Data?
    /// Text file content (already size-capped).
    public var text: String?

    public init(id: UUID = UUID(), kind: Kind, filename: String, mimeType: String, data: Data? = nil, text: String? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.text = text
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: Role
    /// Visible answer text (markdown). For user messages, what the user typed.
    public var content: String
    /// Model "thinking" text, if any. Never sent back to the API.
    public var reasoning: String?
    /// Seconds spent in the reasoning phase, if measured.
    public var reasoningDuration: Double?
    public var attachments: [Attachment]
    public var createdAt: Date
    /// Model that produced an assistant message.
    public var model: String?
    /// False while streaming, or if the stream was stopped/failed before finishing.
    public var isComplete: Bool
    /// Error text if the request failed; shown in the UI under the message.
    public var error: String?
    public var usage: TokenUsage?

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        reasoningDuration: Double? = nil,
        attachments: [Attachment] = [],
        createdAt: Date = Date(),
        model: String? = nil,
        isComplete: Bool = true,
        error: String? = nil,
        usage: TokenUsage? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.attachments = attachments
        self.createdAt = createdAt
        self.model = model
        self.isComplete = isComplete
        self.error = error
        self.usage = usage
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Hashable {
    case low
    case medium
    case high
}

/// Per-conversation request settings.
public struct ConversationSettings: Codable, Hashable, Sendable {
    public var providerID: UUID?
    public var model: String
    public var systemPrompt: String
    public var temperature: Double?
    public var maxTokens: Int?
    /// Sent as `reasoning_effort` when non-nil.
    public var reasoningEffort: ReasoningEffort?

    public init(
        providerID: UUID? = nil,
        model: String = "",
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
    }
}

public struct ForkOrigin: Codable, Hashable, Sendable {
    public var conversationID: UUID
    public var messageID: UUID

    public init(conversationID: UUID, messageID: UUID) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: ConversationSettings
    /// Linear history, oldest first. The system prompt lives in `settings`, not here.
    public var messages: [Message]
    public var forkedFrom: ForkOrigin?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        settings: ConversationSettings = ConversationSettings(),
        messages: [Message] = [],
        forkedFrom: ForkOrigin? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
        self.messages = messages
        self.forkedFrom = forkedFrom
    }

    /// Keeps messages[0...index] and drops the rest (rollback).
    public mutating func truncate(keepingThrough index: Int) {
        guard index >= -1, index < messages.count else { return }
        messages = Array(messages.prefix(index + 1))
        updatedAt = Date()
    }

    /// A new conversation containing messages[0...index] (fork). Gets a fresh id.
    public func forked(through index: Int) -> Conversation {
        let clamped = min(max(index, -1), messages.count - 1)
        let prefix = Array(messages.prefix(clamped + 1))
        let now = Date()
        return Conversation(
            id: UUID(),
            title: title + " (fork)",
            createdAt: now,
            updatedAt: now,
            settings: settings,
            messages: prefix,
            forkedFrom: prefix.last.map { ForkOrigin(conversationID: id, messageID: $0.id) }
        )
    }
}

/// An API endpoint profile. The API key is NOT stored here; it lives in the Keychain
/// keyed by `id` (see KeychainStore).
public struct Provider: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Base URL including the version path, e.g. "http://192.168.1.20:1234/v1"
    /// or "https://api.openai.com/v1". `chat/completions` and `models` are appended.
    public var baseURL: String
    public var defaultModel: String

    public init(id: UUID = UUID(), name: String, baseURL: String, defaultModel: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
    }
}

public enum ParleyError: LocalizedError, Equatable {
    case wrongPassword
    case notAConversationFile
    case unsupportedVersion(Int)
    case corruptFile(String)
    case keychain(Int32)
    case invalidBaseURL(String)
    case http(status: Int, body: String)
    case api(String)
    case unsupportedAttachment(String)
    case attachmentTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Wrong password, or the file has been tampered with."
        case .notAConversationFile: return "This file is not a Parley conversation."
        case .unsupportedVersion(let v): return "Unsupported conversation file version \(v)."
        case .corruptFile(let why): return "The conversation file is damaged: \(why)"
        case .keychain(let status): return "Keychain error (OSStatus \(status))."
        case .invalidBaseURL(let s): return "Invalid API base URL: \(s)"
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .api(let msg): return "API error: \(msg)"
        case .unsupportedAttachment(let name): return "Unsupported file type: \(name)"
        case .attachmentTooLarge(let name): return "File is too large: \(name)"
        }
    }
}
