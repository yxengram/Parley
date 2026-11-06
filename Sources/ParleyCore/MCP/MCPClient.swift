import Foundation

/// One tools/list: what can be used, what cannot and why, and how long it stays fresh.
struct MCPToolList: Sendable, Equatable {
    var tools: [MCPTool]
    var hidden: [MCPHiddenTool]
    /// `ttlMs`, when positive (modern servers).
    var ttl: TimeInterval?
}

/// The protocol, above a transport: era detection, the handshake, tools/list, tools/call.
///
/// Parley opens with `initialize` and falls forward to `server/discover` when that is rejected. The
/// spec's stdio binding suggests probing with discover first, but legacy is the deployed norm and
/// the probe's failure modes hit exactly those servers: it stalls against silent ones, and some
/// exit on it, which would force a second `npx` start. A modern-only server rejects initialize and
/// a dual-era one serves it, so this order reaches every case without a timeout or a respawn.
final class MCPClient: @unchecked Sendable {
    static let listTimeout: TimeInterval = 30
    static let maxListPages = 50
    static let maxTools = 1_000
    static let maxInputRounds = 8

    private let transport: MCPTransport
    private let clientVersion: String
    private let startupTimeout: TimeInterval

    private let lock = NSLock()
    private var nextID = 0
    private var currentEra: MCPEra = .legacy
    private var negotiatedVersion: String?
    private var server: String?
    private var capabilities: JSONValue?
    private var toolsChanged = false
    /// Legacy HTTP: the server's session is gone and no new initialize has succeeded yet.
    private var needsSession = false

    init(transport: MCPTransport, clientVersion: String, startupTimeout: TimeInterval) {
        self.transport = transport
        self.clientVersion = clientVersion
        self.startupTimeout = startupTimeout
        transport.onInbound = { [weak self] message in self?.received(message) }
    }

    // MARK: State

    var era: MCPEra {
        lock.lock(); defer { lock.unlock() }
        return currentEra
    }

    var protocolVersion: String? {
        lock.lock(); defer { lock.unlock() }
        return negotiatedVersion
    }

    /// `name version`, as the server says. Display only.
    var serverInfo: String? {
        lock.lock(); defer { lock.unlock() }
        return server
    }

    var hasTools: Bool {
        lock.lock(); defer { lock.unlock() }
        return capabilities?["tools"] != nil
    }

    /// The server promises `notifications/tools/list_changed`.
    var announcesListChanges: Bool {
        lock.lock(); defer { lock.unlock() }
        return capabilities?["tools"]?["listChanged"]?.boolValue == true
    }

    /// A list_changed arrived since the last tools/list.
    var toolsAreStale: Bool {
        lock.lock(); defer { lock.unlock() }
        return toolsChanged
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func setVerdict(era: MCPEra, version: String, capabilities: JSONValue?, serverInfo: JSONValue?) {
        lock.lock(); defer { lock.unlock() }
        currentEra = era
        negotiatedVersion = version
        if era == .modern { needsSession = false }
        self.capabilities = capabilities
        if let name = serverInfo?["name"]?.stringValue {
            server = [name, serverInfo?["version"]?.stringValue].compactMap { $0 }.joined(separator: " ")
        } else {
            server = nil
        }
    }

    private var clientInfo: JSONValue {
        .object(["name": .string("Parley"), "version": .string(clientVersion)])
    }

    // MARK: Connecting

    /// Finds the era and shakes hands. `preferModern`: this server was modern earlier in this launch,
    /// so skip the failing initialize; a server that no longer is gets the full detection.
    func connect(preferModern: Bool = false) async throws {
        if preferModern {
            do {
                try await discover(timeout: startupTimeout)
                return
            } catch {
                if error is CancellationError { throw error }
            }
        }
        do {
            try await initialize()
        } catch {
            guard Self.mayMeanModern(error) else { throw error }
            do {
                try await discover(timeout: startupTimeout)
            } catch let later {
                if case MCPError.unsupportedVersion = later { throw later }
                throw error
            }
        }
    }

    /// A JSON-RPC error, or HTTP 400/404/405. 401, 403, 5xx, network failure and timeout are never
    /// era evidence.
    private static func mayMeanModern(_ error: Error) -> Bool {
        switch error {
        case MCPError.rpc: return true
        case MCPError.http(let status, _): return status == 400 || status == 404 || status == 405
        default: return false
        }
    }

    private func initialize() async throws {
        lock.withLock { needsSession = true }
        transport.resetSession()
        let params: JSONValue = .object([
            "protocolVersion": .string(MCPProtocol.legacyVersion),
            "capabilities": .object([:]),
            "clientInfo": clientInfo,
        ])
        let response = try await exchange(MCPOutbound(id: allocateID(), method: "initialize", params: params), timeout: startupTimeout)
        let result = try Self.unwrap(response)
        guard let version = result["protocolVersion"]?.stringValue else {
            throw MCPError.invalidResponse("initialize has no protocolVersion")
        }
        guard MCPProtocol.legacyVersions.contains(version) else {
            throw MCPError.unsupportedVersion(version)
        }
        setVerdict(era: .legacy, version: version, capabilities: result["capabilities"], serverInfo: result["serverInfo"])
        if let http = transport as? MCPHTTPTransport { http.setProtocolVersion(version) }
        let initialized = MCPOutbound(method: "notifications/initialized", params: nil, httpHeaders: legacyHeaders())
        let transport = self.transport
        // Inside the start's time limit: a server that never answers this must not hang every reply.
        try await Self.timed(startupTimeout) { try await transport.notify(initialized) }
        lock.withLock { needsSession = false }
    }

    /// A session lost earlier, whose new initialize failed or was cancelled: requests without a
    /// session would never reach the 404 that starts over.
    private func restoreSession() async throws {
        if lock.withLock({ needsSession }) { try await initialize() }
    }

    private func discover(timeout: TimeInterval) async throws {
        let response = try await exchange(modernRequest("server/discover", params: [:]), timeout: timeout)
        if let error = response.error {
            if error.code == MCPProtocol.unsupportedVersion {
                let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !supported.contains(MCPProtocol.modernVersion) {
                    throw MCPError.unsupportedVersion(supported.joined(separator: ", "))
                }
                setVerdict(era: .modern, version: MCPProtocol.modernVersion, capabilities: .object(["tools": .object([:])]), serverInfo: nil)
                return
            }
            throw MCPError.rpc(code: error.code, message: error.message, data: error.data)
        }
        guard let result = response.result else { throw MCPError.invalidResponse("server/discover has no result") }
        let supported = result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard supported.contains(MCPProtocol.modernVersion) else {
            throw MCPError.unsupportedVersion(supported.joined(separator: ", "))
        }
        setVerdict(era: .modern, version: MCPProtocol.modernVersion, capabilities: result["capabilities"],
                   serverInfo: result["_meta"]?[MCPProtocol.metaServerInfo])
    }

    // MARK: Requests

    private func legacyHeaders() -> [String: String] {
        protocolVersion.map { ["MCP-Protocol-Version": $0] } ?? [:]
    }

    /// `params` with the `_meta` every modern request carries, and the HTTP headers that mirror it.
    private func modernRequest(_ method: String, params: [String: JSONValue], extraHeaders: [String: String] = [:]) -> MCPOutbound {
        var params = params
        params["_meta"] = .object([
            MCPProtocol.metaVersion: .string(MCPProtocol.modernVersion),
            MCPProtocol.metaCapabilities: .object([:]),
            MCPProtocol.metaClientInfo: clientInfo,
        ])
        var headers = extraHeaders
        headers["MCP-Protocol-Version"] = MCPProtocol.modernVersion
        headers["Mcp-Method"] = method
        return MCPOutbound(id: allocateID(), method: method, params: .object(params), httpHeaders: headers)
    }

    private func request(_ method: String, params: [String: JSONValue], extraHeaders: [String: String] = [:]) -> MCPOutbound {
        if era == .modern { return modernRequest(method, params: params, extraHeaders: extraHeaders) }
        return MCPOutbound(id: allocateID(), method: method, params: .object(params), httpHeaders: legacyHeaders())
    }

    /// One request against a timeout. Cancelling the Task ends it too.
    private func exchange(_ message: MCPOutbound, timeout: TimeInterval) async throws -> MCPResponse {
        let transport = self.transport
        return try await Self.timed(timeout) { try await transport.send(message) }
    }

    private static func timed<T: Sendable>(_ timeout: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = min(max(0, timeout), MCPServerConfig.maxTimeout)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: body)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPError.streamEnded }
            return first
        }
    }

    private static func unwrap(_ response: MCPResponse) throws -> JSONValue {
        if let error = response.error { throw MCPError.rpc(code: error.code, message: error.message, data: error.data) }
        guard let result = response.result else { throw MCPError.invalidResponse("no result") }
        return result
    }

    /// Modern results say what they are. Absent means complete; anything unknown is invalid.
    private func resultType(_ result: JSONValue) throws -> String {
        guard era == .modern, let type = result["resultType"] else { return "complete" }
        guard let name = type.stringValue, name == "complete" || name == "input_required" else {
            throw MCPError.invalidResponse("unknown resultType")
        }
        return name
    }

    /// A request that may have to start again: after a lost legacy session (the server did not
    /// know it, so nothing ran).
    private func withSession<T>(_ body: () async throws -> T) async throws -> T {
        try await restoreSession()
        do {
            return try await body()
        } catch MCPError.sessionExpired {
            try await initialize()
            return try await body()
        }
    }

    // MARK: tools/list

    /// Every page. An empty string is a valid cursor: only an absent one ends the list.
    func listTools() async throws -> MCPToolList {
        lock.withLock { toolsChanged = false }
        guard hasTools else { return MCPToolList(tools: [], hidden: [], ttl: nil) }
        return try await withSession {
            do {
                return try await listAllPages()
            } catch MCPError.streamEnded {
                // Nothing a list does can repeat a side effect.
                return try await listAllPages()
            }
        }
    }

    private func listAllPages() async throws -> MCPToolList {
        var cursor: String?
        var raw: [JSONValue] = []
        var ttl: TimeInterval? = .infinity
        for _ in 0..<Self.maxListPages {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let message = request("tools/list", params: params)
            let response: MCPResponse
            do {
                response = try await exchange(message, timeout: Self.listTimeout)
            } catch {
                giveUp(on: message, after: error)
                throw error
            }
            let result = try Self.unwrap(response)
            guard try resultType(result) == "complete", let tools = result["tools"]?.arrayValue else {
                throw MCPError.invalidResponse("tools/list has no tools")
            }
            raw += tools
            if raw.count > Self.maxTools { throw MCPError.invalidResponse("more than \(Self.maxTools) tools") }
            if let milliseconds = result["ttlMs"]?.intValue, milliseconds > 0 {
                ttl = ttl.map { min($0, Double(milliseconds) / 1000) }
            } else {
                ttl = nil
            }
            guard let next = result["nextCursor"]?.stringValue else {
                return Self.parse(raw, overHTTP: transport.isHTTP, ttl: ttl.flatMap { $0.isFinite ? $0 : nil }, era: era)
            }
            cursor = next
        }
        throw MCPError.invalidResponse("more than \(Self.maxListPages) pages of tools")
    }

    static func parse(_ raw: [JSONValue], overHTTP: Bool, ttl: TimeInterval?, era: MCPEra) -> MCPToolList {
        var tools: [MCPTool] = []
        var hidden: [MCPHiddenTool] = []
        var seen: Set<String> = []
        for entry in raw {
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { continue }
            guard isDisplayable(name) else {
                hidden.append(MCPHiddenTool(name: String(name.unicodeScalars.prefix(128)),
                                            reason: "Its name is too long, or has spaces or invisible characters."))
                continue
            }
            guard seen.insert(name).inserted else {
                hidden.append(MCPHiddenTool(name: name, reason: "The server lists this name twice."))
                continue
            }
            if era == .legacy, entry["execution"]?["taskSupport"]?.stringValue == "required" {
                hidden.append(MCPHiddenTool(name: name, reason: "It runs only as a task, which Parley does not support."))
                continue
            }
            let schema = MCPSchema.normalized(entry["inputSchema"])
            if overHTTP, let problem = MCPHeaderMirror.annotations(in: schema).problem {
                hidden.append(MCPHiddenTool(name: name, reason: problem))
                continue
            }
            tools.append(MCPTool(name: name, title: entry["title"]?.stringValue,
                                 description: entry["description"]?.stringValue, inputSchema: schema))
        }
        return MCPToolList(tools: tools, hidden: hidden, ttl: ttl)
    }

    /// What the approval card can show as one honest name. The spec's `[A-Za-z0-9_.-]{1,128}` is a
    /// SHOULD and older servers use `:` and `/`, which do no harm here: the model gets a slug, and
    /// the card shows the name exactly. Line breaks and invisible characters are what could fake
    /// the card, and a long name would push its buttons out of reach.
    private static func isDisplayable(_ name: String) -> Bool {
        name.unicodeScalars.count <= 128 && name.unicodeScalars.allSatisfy { scalar in
            let properties = scalar.properties
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .unassigned: return false
            default: return !properties.isDefaultIgnorableCodePoint
            }
        }
    }

    // MARK: tools/call

    /// The raw result. A cancelled or timed-out call tells the server, as its transport requires.
    func callTool(_ tool: MCPTool, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        var schema = tool.inputSchema
        var params: [String: JSONValue] = ["name": .string(tool.name), "arguments": .object(arguments)]
        var inputRounds = 0
        var retriedHeaders = false
        var retriedSession = false
        try await restoreSession()
        while true {
            let message = callRequest(tool.name, schema: schema, params: params, arguments: arguments)
            let response: MCPResponse
            do {
                response = try await exchange(message, timeout: timeout)
            } catch MCPError.sessionExpired where !retriedSession {
                // The server did not know the session, so the tool did not run.
                retriedSession = true
                try await initialize()
                continue
            } catch {
                giveUp(on: message, after: error)
                throw error
            }
            if response.error?.code == MCPProtocol.headerMismatch, transport.isHTTP, !retriedHeaders {
                // Refused before the tool ran: the definition may have changed.
                retriedHeaders = true
                if let fresh = try await listTools().tools.first(where: { $0.name == tool.name }) {
                    schema = fresh.inputSchema
                }
                continue
            }
            let result = try Self.unwrap(response)
            switch try resultType(result) {
            case "input_required":
                if let requests = result["inputRequests"], !requests.isNull, requests.objectValue?.isEmpty != true {
                    throw MCPError.inputNotSupported
                }
                inputRounds += 1
                guard inputRounds <= Self.maxInputRounds else { throw MCPError.inputNotSupported }
                params["requestState"] = result["requestState"]
            default:
                return result
            }
        }
    }

    private static func isTimeout(_ error: MCPError) -> Bool {
        if case .timedOut = error { return true }
        return false
    }

    private func callRequest(_ name: String, schema: JSONValue, params: [String: JSONValue], arguments: [String: JSONValue]) -> MCPOutbound {
        guard era == .modern else { return request("tools/call", params: params) }
        var headers = MCPHeaderMirror.headers(schema: schema, arguments: arguments)
        headers["Mcp-Name"] = MCPHeaderMirror.encoded(name)
        return request("tools/call", params: params, extraHeaders: headers)
    }

    /// A request that was cancelled or timed out is called off with the server; any other failure
    /// means there is nothing left to call off.
    private func giveUp(on message: MCPOutbound, after error: Error) {
        guard error is CancellationError || (error as? MCPError).map(Self.isTimeout) == true else { return }
        cancel(message.id, reason: error is CancellationError ? "The user stopped the reply." : "Timed out.")
    }

    /// stdio, both eras, and legacy HTTP send `notifications/cancelled`. On modern HTTP, closing the
    /// response stream is the cancel signal. Detached: the calling Task is already cancelled.
    private func cancel(_ id: Int?, reason: String) {
        guard let id, !(transport.isHTTP && era == .modern) else { return }
        let notification = MCPOutbound(method: "notifications/cancelled",
                                       params: .object(["requestId": .int(Int64(id)), "reason": .string(reason)]),
                                       httpHeaders: legacyHeaders())
        let transport = self.transport
        Task.detached { try? await transport.notify(notification) }
    }

    // MARK: From the server

    private func received(_ message: MCPInbound) {
        switch message {
        case .notification(let method, _):
            if method == "notifications/tools/list_changed" {
                lock.lock()
                toolsChanged = true
                lock.unlock()
            }
        case .request(let id, let method, _):
            // Modern servers must not send requests, and clients must not answer them.
            guard era == .legacy else { return }
            let reply: (JSONValue?, MCPRPCError?) = method == "ping"
                ? (.object([:]), nil)
                : (nil, MCPRPCError(code: MCPProtocol.methodNotFound, message: "Method not found"))
            let headers = legacyHeaders()
            let transport = self.transport
            Task.detached { try? await transport.respond(to: id, result: reply.0, error: reply.1, headers: headers) }
        case .response:
            break
        }
    }
}
