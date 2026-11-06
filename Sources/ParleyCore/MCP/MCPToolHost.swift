import Foundation

// The contract between the chat side and MCP. ConversationSession sees only this: it never touches
// a transport, and tests can script a host without a server.

public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String?
    /// After MCPSchema.normalized.
    public var inputSchema: JSONValue
    /// First 16 hex of SHA-256 over sorted-key JSON of {name, description, inputSchema, x-mcp-header paths}.
    public var fingerprint: String

    public init(name: String, title: String? = nil, description: String? = nil, inputSchema: JSONValue,
                fingerprint: String? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.fingerprint = fingerprint ?? MCPToolFingerprint.make(name: name, description: description, inputSchema: inputSchema)
    }
}

/// One tool as offered in one reply.
public struct MCPToolBinding: Sendable, Hashable {
    public var exposedName: String
    public var serverID: UUID
    public var serverName: String
    public var tool: MCPTool

    public init(exposedName: String, serverID: UUID, serverName: String, tool: MCPTool) {
        self.exposedName = exposedName
        self.serverID = serverID
        self.serverName = serverName
        self.tool = tool
    }
}

public struct MCPServerFailure: Sendable, Equatable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

public struct MCPHiddenTool: Sendable, Equatable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

public struct MCPToolCatalog: Sendable {
    /// Sorted by exposedName.
    public var bindings: [MCPToolBinding]
    /// Servers that could not be used, for a note: (name, reason).
    public var unavailable: [MCPServerFailure]
    /// Same order as bindings.
    public var chatTools: [ChatTool]
    public var definitionTokens: Int

    public init(bindings: [MCPToolBinding] = [], unavailable: [MCPServerFailure] = []) {
        self.bindings = bindings.sorted { $0.exposedName < $1.exposedName }
        self.unavailable = unavailable
        chatTools = self.bindings.map {
            ChatTool(name: $0.exposedName, description: $0.tool.description, parameters: $0.tool.inputSchema)
        }
        definitionTokens = chatTools.reduce(0) { $0 + ContextBudget.estimateTokens(tool: $1) }
    }

    /// Exact match, then a unique match ignoring case and every non-alphanumeric character
    /// (LM Studio normalizes tool names; whether it returns the normalized form is unconfirmed).
    public func binding(forFunctionName name: String) -> MCPToolBinding? {
        if let exact = bindings.first(where: { $0.exposedName == name }) { return exact }
        func folded(_ s: String) -> String {
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
        }
        let wanted = folded(name)
        guard !wanted.isEmpty else { return nil }
        let matches = bindings.filter { folded($0.exposedName) == wanted }
        return matches.count == 1 ? matches[0] : nil
    }
}

public enum MCPServerState: Sendable, Equatable {
    case stopped, starting, ready
    case restarting(reason: String)
    case failed(String)
}

public struct MCPServerSnapshot: Sendable, Equatable {
    public var serverID: UUID
    public var state: MCPServerState
    public var protocolVersion: String?
    /// Self-reported, unverified, display only.
    public var serverInfo: String?
    public var tools: [MCPTool]
    /// Tools the server listed that Parley cannot use: (name, reason).
    public var hiddenTools: [MCPHiddenTool]
    public var isRunning: Bool

    public init(serverID: UUID, state: MCPServerState = .stopped, protocolVersion: String? = nil, serverInfo: String? = nil,
                tools: [MCPTool] = [], hiddenTools: [MCPHiddenTool] = [], isRunning: Bool = false) {
        self.serverID = serverID
        self.state = state
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
        self.tools = tools
        self.hiddenTools = hiddenTools
        self.isRunning = isRunning
    }
}

public protocol MCPToolHost: AnyObject, Sendable {
    /// Starts what is not running and lists tools. Never throws: a failed server lands in
    /// `unavailable`, with a reason that is safe to save (no stderr, no local folders).
    func catalog(for servers: [MCPServerConfig]) async -> MCPToolCatalog
    /// Runs one approved call. Cancelling the calling Task cancels the call. Never throws. Restarts
    /// a server that crashed, never one the user stopped or removed: those report `notCalled`.
    func call(_ binding: MCPToolBinding, arguments: [String: JSONValue], timeout: TimeInterval,
              maxCharacters: Int) async -> ToolCallResult
    /// User pressed Connect or Restart in Settings.
    func connect(_ server: MCPServerConfig) async -> MCPServerSnapshot
    func stop(serverID: UUID) async
    /// The server was removed: stops it and drops everything kept for it. Nothing starts it again.
    func forget(serverID: UUID) async
    func logs(serverID: UUID) async -> [String]
    /// Lock: stderr goes, from the logs and from the status text that quotes it.
    func clearLogs(serverIDs: [UUID]) async
    /// Every status change, for AppState.
    var updates: AsyncStream<MCPServerSnapshot> { get }
    /// Quit and tests. Synchronous, thread-safe, bounded by about 3 × grace + 1 s, and instant
    /// when nothing runs.
    func shutdownSync(grace: TimeInterval)
}
