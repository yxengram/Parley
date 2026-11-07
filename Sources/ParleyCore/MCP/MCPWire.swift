import Foundation

// JSON-RPC 2.0 as MCP uses it, and the protocol's fixed names. Two eras exist: `legacy` servers
// start with an initialize handshake (2025-11-25 and earlier), `modern` ones are stateless and
// carry the version in every request's _meta (2026-07-28).

public enum MCPEra: String, Sendable {
    case legacy, modern
}

public enum MCPProtocol {
    public static let modernVersion = "2026-07-28"
    public static let legacyVersion = "2025-11-25"
    /// What `initialize` accepts back. 2024-10-07 is not a published revision, but the TypeScript
    /// SDK still accepts it.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    static let methodNotFound = -32601
    static let headerMismatch = -32020
    static let unsupportedVersion = -32022

    /// A single message past this is a failure, on stdio and HTTP.
    static let maxMessageBytes = 16 * 1024 * 1024
}

public struct MCPRPCError: Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum MCPError: LocalizedError, Equatable {
    case commandNotFound(name: String, searched: [String])
    /// The path exists, but it cannot be run.
    case notExecutable(String)
    case spawnFailed(String)
    case exited(status: Int32, stderrTail: [String])
    case startupTimedOut(seconds: Double, stderrTail: [String])
    case unsupportedVersion(String)
    case rpc(code: Int, message: String, data: JSONValue?)
    case http(status: Int, body: String)
    case needsAuthorization(status: Int)
    /// A refusal on a server that cannot sign in: it has a static Authorization header, or it is plain
    /// http off this Mac.
    case credentialsRefused(status: Int)
    /// A Bearer 403 with `insufficient_scope`: the sign-in is fine, it does not reach far enough.
    case insufficientScope
    /// Sign-in itself failed. Fixed text only.
    case oauth(MCPOAuthFailure)
    case refusedRedirect(String)
    case messageTooLarge
    case invalidResponse(String)
    case streamEnded
    case sessionExpired
    case secrets(String)
    case unknownKind(String)
    case timedOut(seconds: Double)
    case invalidHeader(String)
    case invalidURL
    case disabled
    case notConfigured
    case inputNotSupported
    /// The user stopped this server. Only a new reply or Connect starts it again.
    case stopped
    case tooManyCrashes(limit: Int)

    public var errorDescription: String? {
        func withLog(_ text: String, _ tail: [String]) -> String {
            tail.isEmpty ? text : text + "\n" + tail.joined(separator: "\n")
        }
        switch self {
        case .commandNotFound(let name, let searched):
            if Self.isCommandLine(name) { return Self.commandLineAdvice }
            return "Could not find \(name). Searched: \(searched.joined(separator: ", ")). Use an absolute path, or set PATH in this server's environment."
        case .notExecutable(let path): return "\(path) exists but is not a program Parley can run."
        case .spawnFailed(let why): return "Could not start the server: \(why)"
        case .exited(let status, let tail):
            return withLog(status == 0 ? "The server stopped (status 0). This program may not be an MCP server." : "The server stopped (status \(status)).", tail)
        case .startupTimedOut(let seconds, let tail):
            return withLog("The server did not answer within \(Int(seconds.rounded())) seconds.", tail)
        case .unsupportedVersion(let version): return "The server speaks an MCP version Parley does not support (\(version))."
        case .rpc(let code, let message, _):
            return code == 0 ? "The server reported an error: \(message)" : "The server reported an error (\(code)): \(message)"
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .needsAuthorization(let status):
            if status == 401 {
                return "This server needs you to sign in. Press Sign In in Settings > MCP, or add a static Authorization header if the server accepts one."
            }
            return "The server refused the request (HTTP \(status)). Check your access to this server and any headers set for it."
        case .credentialsRefused(let status):
            return "The server refused the request (HTTP \(status)). Check this server's Authorization header. Sign-in needs https."
        case .insufficientScope:
            return "This server needs more permission for that. Press Sign In in Settings > MCP to grant it."
        case .oauth(let failure): return failure.text
        case .refusedRedirect(let line): return line
        case .messageTooLarge: return "The server sent a message over 16 MB."
        case .invalidResponse(let why): return "The server sent an invalid response: \(why)"
        case .streamEnded: return "The connection closed before the server answered."
        case .sessionExpired: return "The server no longer knows this session."
        case .secrets(let why): return why
        case .unknownKind(let kind): return "This version of Parley does not know the server type \(kind)."
        case .timedOut(let seconds): return "The server did not answer within \(Int(seconds.rounded())) seconds."
        case .invalidHeader(let name): return "The header \(name) has an empty name or a line break, so it cannot be sent."
        case .invalidURL: return "The server's URL is not a valid http or https URL."
        case .disabled: return "This server is turned off."
        case .notConfigured: return "This server is no longer configured."
        case .inputNotSupported: return "The tool asked for input Parley does not support."
        case .stopped: return "This server was stopped."
        case .tooManyCrashes(let limit):
            return "The server stopped \(limit) times in a minute. Press Connect in Settings > MCP to try again."
        }
    }

    /// For what is saved in a conversation or sent to the model: without the server's stderr, which
    /// can hold tokens, and without folders on this Mac. `errorDescription` keeps both, for the status
    /// in Settings.
    public var summary: String {
        switch self {
        case .commandNotFound(let name, _):
            if Self.isCommandLine(name) { return Self.commandLineAdvice }
            let program = (name as NSString).lastPathComponent
            let source = ["npx": "Node.js", "npm": "Node.js", "node": "Node.js", "uvx": "uv", "uv": "uv"][program]
            return "Could not find \(program)\(source.map { " (it comes with \($0))" } ?? ""). Install it, or give its full path in Settings > MCP."
        case .notExecutable: return "The server's program cannot be run. Check it in Settings > MCP."
        case .exited, .startupTimedOut:
            return (withoutLog.errorDescription ?? "") + " See its log in Settings > MCP."
        default:
            return errorDescription ?? ""
        }
    }

    /// The same error, without the lines of stderr it carries.
    var withoutLog: MCPError {
        switch self {
        case .exited(let status, _): return .exited(status: status, stderrTail: [])
        case .startupTimedOut(let seconds, _): return .startupTimedOut(seconds: seconds, stderrTail: [])
        default: return self
        }
    }

    /// Someone typed the whole command line where the program goes.
    private static func isCommandLine(_ name: String) -> Bool {
        name.contains(" ") && !name.hasPrefix("/") && !name.hasPrefix("~")
    }

    private static let commandLineAdvice = "The command contains spaces. Put the program in Command and the rest under Arguments."
}

/// One message from the server.
enum MCPInbound: Sendable, Equatable {
    case response(id: JSONValue, result: JSONValue?, error: MCPRPCError?)
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
}

/// One message to the server. `httpHeaders` are ignored on stdio.
struct MCPOutbound: Sendable {
    var id: Int?
    var method: String
    var params: JSONValue?
    var httpHeaders: [String: String] = [:]
}

/// The answer to one request: `result` or `error`.
struct MCPResponse: Sendable, Equatable {
    var result: JSONValue?
    var error: MCPRPCError?
}

enum MCPWire {
    /// One JSON-RPC message on one line: JSONSerialization without pretty printing escapes every
    /// newline, and stdio frames depend on that.
    static func encode(_ message: MCPOutbound) -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(message.method)]
        if let id = message.id { object["id"] = .int(Int64(id)) }
        if let params = message.params { object["params"] = params }
        return JSONValue.object(object).sortedJSONData
    }

    static func encodeResponse(id: JSONValue, result: JSONValue?, error: MCPRPCError?) -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        if let error {
            var body: [String: JSONValue] = ["code": .int(Int64(error.code)), "message": .string(error.message)]
            if let data = error.data { body["data"] = data }
            object["error"] = .object(body)
        } else {
            object["result"] = result ?? .object([:])
        }
        return JSONValue.object(object).sortedJSONData
    }

    /// One object, or an array of them (2025-03-26 servers may batch). Nil when it is not JSON-RPC.
    static func decode(_ data: Data) -> [MCPInbound]? {
        guard let value = JSONValue(jsonData: data) else { return nil }
        if case .array(let items) = value {
            // One bad item must not lose the responses beside it.
            let decoded = items.compactMap(decodeOne)
            return decoded.isEmpty && !items.isEmpty ? nil : decoded
        }
        return decodeOne(value).map { [$0] }
    }

    private static func decodeOne(_ value: JSONValue) -> MCPInbound? {
        guard case .object(let object) = value else { return nil }
        if let method = object["method"]?.stringValue {
            if let id = object["id"], !id.isNull {
                return .request(id: id, method: method, params: object["params"])
            }
            return .notification(method: method, params: object["params"])
        }
        // A rejection that could not be tied to a request has a null or missing id.
        let id = object["id"] ?? .null
        if let error = object["error"], !error.isNull {
            return .response(id: id, result: nil, error: rpcError(error))
        }
        guard let result = object["result"] else { return nil }
        return .response(id: id, result: result, error: nil)
    }

    private static func rpcError(_ value: JSONValue) -> MCPRPCError {
        MCPRPCError(code: value["code"]?.intValue.map(Int.init) ?? 0,
                    message: value["message"]?.stringValue ?? "Unknown error",
                    data: value["data"])
    }
}
