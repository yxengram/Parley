import CryptoKit
import Foundation

// What the user configured for one MCP server, split by what may be seen. The config goes to
// preferences; everything that can hold a token goes to the Keychain as MCPServerSecrets.

public struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    public static let kindStdio = "stdio", kindHTTP = "http"
    /// Parley's own tools (BuiltInTools). Never stored, never reaches a transport.
    public static let kindBuiltIn = "builtin"
    public static let defaultCallTimeout: Double = 120
    public static let defaultMaxResultCharacters = 32_000
    /// A week: past this a timeout means nothing, and the conversions to nanoseconds and Int can trap.
    public static let maxTimeout: Double = 604_800

    public var id: UUID
    public var name: String
    /// A String, so a later kind cannot break the whole list.
    public var kind: String
    /// stdio: the program only; arguments are secrets.
    public var command: String
    public var workingDirectory: String?
    /// http: host for display; the full URL is a secret.
    public var urlHost: String
    /// Values are in the Keychain.
    public var envNames: [String]
    /// Values are in the Keychain.
    public var headerNames: [String]
    /// Master switch: false never starts, whatever a conversation lists.
    public var isEnabled: Bool
    public var useInNewChats: Bool
    public var disabledTools: [String]
    /// Tool name → MCPTool.fingerprint at the time of "Always Allow".
    public var alwaysAllowedTools: [String: String]
    /// Nil: 120 s stdio (a first `npx` may download), 20 s http.
    public var startupTimeout: Double?
    /// Nil: `defaultCallTimeout`.
    public var callTimeout: Double?
    /// Nil: `defaultMaxResultCharacters`.
    public var maxResultCharacters: Int?
    /// Stored hashes, set from `fingerprints(config:secrets:)` when the server is saved, where config
    /// and secrets are both at hand. SHA-256, so preferences reveal nothing of the secrets.
    /// Over kind, command, args, workingDirectory, url, envNames, headerNames: a running connection
    /// whose value differs is replaced.
    public var connectionFingerprint: String
    /// Over kind, command, args, url, workingDirectory and the server's own PATH, which can each
    /// change the program that runs: a change clears `alwaysAllowedTools`.
    public var identityFingerprint: String

    public init(id: UUID = UUID(), name: String, kind: String = MCPServerConfig.kindStdio, command: String = "",
                workingDirectory: String? = nil, urlHost: String = "", envNames: [String] = [], headerNames: [String] = [],
                isEnabled: Bool = true, useInNewChats: Bool = false, disabledTools: [String] = [],
                alwaysAllowedTools: [String: String] = [:], startupTimeout: Double? = nil, callTimeout: Double? = nil,
                maxResultCharacters: Int? = nil, connectionFingerprint: String = "", identityFingerprint: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.workingDirectory = workingDirectory
        self.urlHost = urlHost
        self.envNames = envNames
        self.headerNames = headerNames
        self.isEnabled = isEnabled
        self.useInNewChats = useInNewChats
        self.disabledTools = disabledTools
        self.alwaysAllowedTools = alwaysAllowedTools
        self.startupTimeout = startupTimeout
        self.callTimeout = callTimeout
        self.maxResultCharacters = maxResultCharacters
        self.connectionFingerprint = connectionFingerprint
        self.identityFingerprint = identityFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, command, workingDirectory, urlHost, envNames, headerNames, isEnabled, useInNewChats,
             disabledTools, alwaysAllowedTools, startupTimeout, callTimeout, maxResultCharacters,
             connectionFingerprint, identityFingerprint
    }

    /// Everything but the id has a default, so a field a later version adds or an earlier one
    /// lacked cannot drop the server from the list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "MCP Server",
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? Self.kindStdio,
            command: try c.decodeIfPresent(String.self, forKey: .command) ?? "",
            workingDirectory: try c.decodeIfPresent(String.self, forKey: .workingDirectory),
            urlHost: try c.decodeIfPresent(String.self, forKey: .urlHost) ?? "",
            envNames: try c.decodeIfPresent([String].self, forKey: .envNames) ?? [],
            headerNames: try c.decodeIfPresent([String].self, forKey: .headerNames) ?? [],
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            useInNewChats: try c.decodeIfPresent(Bool.self, forKey: .useInNewChats) ?? false,
            disabledTools: try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? [],
            alwaysAllowedTools: try c.decodeIfPresent([String: String].self, forKey: .alwaysAllowedTools) ?? [:],
            startupTimeout: try c.decodeIfPresent(Double.self, forKey: .startupTimeout),
            callTimeout: try c.decodeIfPresent(Double.self, forKey: .callTimeout),
            maxResultCharacters: try c.decodeIfPresent(Int.self, forKey: .maxResultCharacters),
            connectionFingerprint: try c.decodeIfPresent(String.self, forKey: .connectionFingerprint) ?? "",
            identityFingerprint: try c.decodeIfPresent(String.self, forKey: .identityFingerprint) ?? ""
        )
    }

    public var effectiveStartupTimeout: Double {
        min(startupTimeout ?? (kind == Self.kindHTTP ? 20 : 120), Self.maxTimeout)
    }

    public var effectiveCallTimeout: Double { min(callTimeout ?? Self.defaultCallTimeout, Self.maxTimeout) }

    public var effectiveMaxResultCharacters: Int { maxResultCharacters ?? Self.defaultMaxResultCharacters }

    /// The two stored hashes. `\u{1F}` separates fields, so moving text between them changes the hash.
    public static func fingerprints(config: MCPServerConfig, secrets: MCPServerSecrets) -> (connection: String, identity: String) {
        func hash(_ fields: [String]) -> String {
            SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let identity = [config.kind, config.command] + secrets.args
            + ["\u{1E}", secrets.url, config.workingDirectory ?? "", secrets.env["PATH"] ?? ""]
        let connection = identity + ["\u{1E}"] + config.envNames.sorted() + ["\u{1E}"] + config.headerNames.sorted()
        return (hash(connection), hash(identity))
    }
}

/// Everything that can hold a token. Pasted configs carry them in arguments
/// (`mcp-remote … --header "Authorization: Bearer …"`) and in URL paths, not only in env and headers.
public struct MCPServerSecrets: Codable, Hashable, Sendable {
    public var args: [String] = []
    public var url: String = ""
    public var env: [String: String] = [:]
    public var headers: [String: String] = [:]
    /// Sign-in with a client registered by hand. Empty: Parley registers one if the provider allows.
    /// An https URL works as a Client ID Metadata Document, on a provider that says it accepts them.
    public var oauthClientID: String = ""
    public var oauthClientSecret: String = ""
    /// For a provider that needs the exact redirect URI registered. Nil: a free port.
    public var oauthCallbackPort: Int?

    public init(args: [String] = [], url: String = "", env: [String: String] = [:], headers: [String: String] = [:],
                oauthClientID: String = "", oauthClientSecret: String = "", oauthCallbackPort: Int? = nil) {
        self.args = args
        self.url = url
        self.env = env
        self.headers = headers
        self.oauthClientID = oauthClientID
        self.oauthClientSecret = oauthClientSecret
        self.oauthCallbackPort = oauthCallbackPort
    }

    private enum CodingKeys: String, CodingKey { case args, url, env, headers, oauthClientID, oauthClientSecret, oauthCallbackPort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        oauthClientID = try c.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        oauthClientSecret = try c.decodeIfPresent(String.self, forKey: .oauthClientSecret) ?? ""
        oauthCallbackPort = try c.decodeIfPresent(Int.self, forKey: .oauthCallbackPort)
    }

    /// A static Authorization header means this server does not use sign-in: no button, no token.
    public var usesStaticAuthorization: Bool {
        headers.keys.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization" }
    }

    /// The first header that could not be sent as written: a line break would let a pasted value
    /// add headers of its own. Refused when saving, and again when connecting.
    public var invalidHeaderName: String? {
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let bad: (Unicode.Scalar) -> Bool = { $0 == "\r" || $0 == "\n" }
            if name.isEmpty || name.unicodeScalars.contains(where: bad) || value.unicodeScalars.contains(where: bad) {
                return name
            }
        }
        return nil
    }
}

public protocol MCPSecretStore: Sendable {
    func secrets(for serverID: UUID) throws -> MCPServerSecrets
    /// Empty secrets delete the item.
    func setSecrets(_ secrets: MCPServerSecrets, for serverID: UUID) throws
    func deleteSecrets(for serverID: UUID) throws
}

/// One Keychain item per server (account = server UUID), holding JSON. Read at server start and
/// when the editor opens, never at launch.
public struct KeychainMCPSecretStore: MCPSecretStore {
    private let service: String

    public init(service: String = KeychainStore.mcpService) {
        self.service = service
    }

    public func secrets(for serverID: UUID) throws -> MCPServerSecrets {
        guard let text = try KeychainStore.value(service: service, account: serverID.uuidString) else {
            return MCPServerSecrets()
        }
        do {
            return try JSONDecoder().decode(MCPServerSecrets.self, from: Data(text.utf8))
        } catch {
            throw MCPError.secrets("The Keychain item for this server could not be read.")
        }
    }

    public func setSecrets(_ secrets: MCPServerSecrets, for serverID: UUID) throws {
        if secrets == MCPServerSecrets() {
            try deleteSecrets(for: serverID)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(secrets), as: UTF8.self)
        try KeychainStore.setValue(text, service: service, account: serverID.uuidString, label: "Parley MCP server secrets")
    }

    public func deleteSecrets(for serverID: UUID) throws {
        try KeychainStore.deleteValue(service: service, account: serverID.uuidString)
    }
}

/// For tests and the snapshot harness.
public final class InMemoryMCPSecretStore: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: MCPServerSecrets] = [:]
    private var reads = 0

    public init() {}

    /// How many times `secrets(for:)` ran, so a test can prove a path reads nothing.
    public var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    public func secrets(for serverID: UUID) throws -> MCPServerSecrets {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return items[serverID] ?? MCPServerSecrets()
    }

    public func setSecrets(_ secrets: MCPServerSecrets, for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        items[serverID] = secrets == MCPServerSecrets() ? nil : secrets
    }

    public func deleteSecrets(for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        items[serverID] = nil
    }
}
