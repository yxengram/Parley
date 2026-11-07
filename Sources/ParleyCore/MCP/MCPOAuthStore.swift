import Foundation

// What sign-in keeps. Two Keychain items per server, under their own service, and never in
// MCPServerSecrets: the editor's Save rewrites that item from its draft, so it would lose them or
// pull them into the form. Read at server start and when the editor opens, never at launch.

/// One sign-in. `description` is redacted: this value must never reach a log or an error string.
public struct MCPOAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    /// Nil: the provider did not say, so the token is used until a 401.
    public var expiresAt: Date?
    public var issuer: String
    /// The validated metadata string, sent verbatim. A token goes only to a URL this still matches.
    public var resource: String
    public var tokenEndpoint: String
    /// What was requested, so a step-up can ask for the union.
    public var scopes: [String]
    public var clientID: String
    public var clientSecret: String?
    public var authMethod: String

    public var description: String { "MCPOAuthTokens(redacted)" }
    public var debugDescription: String { description }
}

/// A client known to one authorization server. Kept when a token dies, so a new Sign In leaves no
/// second record at the provider; `invalid_client` removes it.
public struct MCPOAuthClient: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var clientID: String
    public var clientSecret: String?
    public var authMethod: String
    /// Registered exactly: a later Sign In binds this port again, or registers anew.
    public var redirectURI: String?
    /// Entered by the user: an error if the provider changes, never silently sent to the new one.
    public var isUserEntered: Bool

    public var description: String { "MCPOAuthClient(redacted)" }
    public var debugDescription: String { description }
}

public protocol MCPOAuthStore: Sendable {
    func tokens(for serverID: UUID) throws -> MCPOAuthTokens?
    func setTokens(_ tokens: MCPOAuthTokens, for serverID: UUID) throws
    func deleteTokens(for serverID: UUID) throws
    /// By issuer: credentials from one authorization server are never tried at another.
    func clients(for serverID: UUID) throws -> [String: MCPOAuthClient]
    /// Empty deletes the item.
    func setClients(_ clients: [String: MCPOAuthClient], for serverID: UUID) throws
}

/// Generic passwords, non-synchronizable like every other Parley item.
public struct KeychainMCPOAuthStore: MCPOAuthStore {
    public static let service = "local.parley.chat.mcp.oauth"
    private let service: String

    public init(service: String = KeychainMCPOAuthStore.service) {
        self.service = service
    }

    private func clientAccount(_ serverID: UUID) -> String { serverID.uuidString + ".client" }

    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let text = try KeychainStore.value(service: service, account: account) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw MCPError.secrets("The Keychain item for this server's sign-in could not be read.")
        }
    }

    private func write<T: Encodable>(_ value: T, account: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        try KeychainStore.setValue(text, service: service, account: account, label: "Parley MCP sign-in")
    }

    public func tokens(for serverID: UUID) throws -> MCPOAuthTokens? {
        try read(MCPOAuthTokens.self, account: serverID.uuidString)
    }

    public func setTokens(_ tokens: MCPOAuthTokens, for serverID: UUID) throws {
        try write(tokens, account: serverID.uuidString)
    }

    public func deleteTokens(for serverID: UUID) throws {
        try KeychainStore.deleteValue(service: service, account: serverID.uuidString)
    }

    public func clients(for serverID: UUID) throws -> [String: MCPOAuthClient] {
        try read([String: MCPOAuthClient].self, account: clientAccount(serverID)) ?? [:]
    }

    public func setClients(_ clients: [String: MCPOAuthClient], for serverID: UUID) throws {
        if clients.isEmpty {
            try KeychainStore.deleteValue(service: service, account: clientAccount(serverID))
        } else {
            try write(clients, account: clientAccount(serverID))
        }
    }
}

/// For tests and the snapshot harness.
public final class InMemoryMCPOAuthStore: MCPOAuthStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokenItems: [UUID: MCPOAuthTokens] = [:]
    private var clientItems: [UUID: [String: MCPOAuthClient]] = [:]
    private var failsWrites = false

    public init() {}

    /// A Keychain that refuses to save.
    public func failWrites(_ fails: Bool) {
        lock.lock(); defer { lock.unlock() }
        failsWrites = fails
    }

    public func tokens(for serverID: UUID) throws -> MCPOAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokenItems[serverID]
    }

    public func setTokens(_ tokens: MCPOAuthTokens, for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if failsWrites { throw MCPError.secrets("write refused") }
        tokenItems[serverID] = tokens
    }

    public func deleteTokens(for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        tokenItems[serverID] = nil
    }

    public func clients(for serverID: UUID) throws -> [String: MCPOAuthClient] {
        lock.lock(); defer { lock.unlock() }
        return clientItems[serverID] ?? [:]
    }

    public func setClients(_ clients: [String: MCPOAuthClient], for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        clientItems[serverID] = clients.isEmpty ? nil : clients
    }
}
