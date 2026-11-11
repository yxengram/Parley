import Foundation

/// Owns every server connection: one process per server, however many conversations use it,
/// started lazily and restarted after a crash with a visible status. A timer never starts anything;
/// only a use does.
public actor MCPConnectionManager: MCPToolHost {
    private final class Connection {
        var config: MCPServerConfig
        var generation = 0
        var state: MCPServerState = .stopped
        var client: MCPClient?
        var transport: MCPTransport?
        var startTask: Task<Void, Never>?
        var startError: Error?
        var tools: MCPToolList?
        /// When `tools` stop being fresh (modern `ttlMs`).
        var freshUntil: Date?
        /// `tools` were listed by the start itself, so the next catalog need not list again.
        var justListed = false
        var crashes: [Date] = []
        var crashedOut = false
        var isModern = false
        /// `state`'s text without stderr, for when Lock clears the log.
        var stateSummary: String?
        /// Why the connection ended during a start, which reports it.
        var closeError: Error?
        /// The user pressed Stop, saved a change or switched the server off. A reply in progress
        /// must not bring it back; only a new `catalog` or `connect` does.
        var stoppedByUser = false
        /// This server may sign in: an HTTP server with no static Authorization header.
        var usesSignIn = false
        var signInNeed: MCPSignInNeed = .none
        let log: MCPLogBuffer

        init(config: MCPServerConfig, log: MCPLogBuffer) {
            self.config = config
            self.log = log
        }
    }

    public nonisolated let updates: AsyncStream<MCPServerSnapshot>
    private nonisolated let updatesContinuation: AsyncStream<MCPServerSnapshot>.Continuation
    private nonisolated let registry = MCPProcessRegistry()
    private let secrets: MCPSecretStore
    private let pathResolver: ShellPATHResolver
    private let clientVersion: String
    private var connections: [UUID: Connection] = [:]
    /// Removed servers: a late use has no config it may start.
    private var forgotten: Set<UUID> = []
    private let oauthStore: MCPOAuthStore
    private var brokers: [UUID: MCPOAuthBroker] = [:]
    private var signIns: [UUID: Task<Void, Error>] = [:]
    private nonisolated let quitting = MCPOAuthFlag()

    private static let crashWindow: TimeInterval = 60
    private static let crashLimit = 3
    /// How long each step of stopping a server waits for it (2 s by default; quit passes its own).
    private nonisolated let stopGrace: TimeInterval

    public init(secrets: MCPSecretStore, oauthStore: MCPOAuthStore = KeychainMCPOAuthStore(),
                pathResolver: ShellPATHResolver = ShellPATHResolver(),
                clientVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0",
                stopGrace: TimeInterval = 2) {
        self.secrets = secrets
        self.oauthStore = oauthStore
        self.pathResolver = pathResolver
        self.clientVersion = clientVersion
        self.stopGrace = stopGrace
        (updates, updatesContinuation) = AsyncStream.makeStream(of: MCPServerSnapshot.self, bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: MCPToolHost

    public func catalog(for servers: [MCPServerConfig]) async -> MCPToolCatalog {
        let usable = servers.filter(\.isEnabled)
        var listed: [(config: MCPServerConfig, tools: [MCPTool])] = []
        var failures: [MCPServerFailure] = []
        // One slow first start must not hold back the others.
        await withTaskGroup(of: (MCPServerConfig, Result<[MCPTool], Error>).self) { group in
            for server in usable {
                group.addTask { (server, await self.tools(of: server)) }
            }
            for await (server, outcome) in group {
                switch outcome {
                case .success(let tools):
                    listed.append((server, tools.filter { !server.disabledTools.contains($0.name) }))
                case .failure(let error):
                    if !(error is CancellationError) {
                        failures.append(MCPServerFailure(name: server.name, reason: Self.summary(error)))
                    }
                }
            }
        }
        failures.sort { $0.name < $1.name }
        return MCPToolCatalog(bindings: MCPToolNamer.assign(listed), unavailable: failures)
    }

    private func tools(of server: MCPServerConfig) async -> Result<[MCPTool], Error> {
        var used: MCPClient?
        do {
            connections[server.id]?.stoppedByUser = false
            let client = try await client(for: server)
            used = client
            guard let connection = connections[server.id] else { throw MCPError.notConfigured }
            if needsListing(connection, client) {
                let generation = connection.generation
                let list = try await client.listTools()
                if connection.generation == generation {
                    store(list, in: connection)
                    publish(connection)
                }
            }
            connection.justListed = false
            return .success(connection.tools?.tools ?? [])
        } catch {
            await authorizationFailed(serverID: server.id, client: used, error: error)
            return .failure(error)
        }
    }

    /// Legacy stdio with list_changed: cached until told otherwise. Other legacy servers: each
    /// reply. Modern: for `ttlMs`.
    private func needsListing(_ connection: Connection, _ client: MCPClient) -> Bool {
        guard connection.tools != nil else { return true }
        if client.toolsAreStale { return true }
        if connection.justListed { return false }
        if client.era == .modern {
            guard let until = connection.freshUntil else { return true }
            return Date() >= until
        }
        return connection.config.kind == MCPServerConfig.kindHTTP || !client.announcesListChanges
    }

    private func store(_ list: MCPToolList, in connection: Connection) {
        connection.tools = list
        connection.freshUntil = list.ttl.map { Date().addingTimeInterval($0) }
    }

    public func call(_ binding: MCPToolBinding, arguments: [String: JSONValue], timeout: TimeInterval,
                     maxCharacters: Int) async -> ToolCallResult {
        let started = Date()
        func finished(_ result: ToolCallResult) -> ToolCallResult {
            var result = result
            result.duration = Date().timeIntervalSince(started)
            return result
        }
        let client: MCPClient
        do {
            guard let connection = connections[binding.serverID] else { throw MCPError.notConfigured }
            if connection.stoppedByUser { throw MCPError.stopped }
            client = try await self.client(for: connection.config)
        } catch is CancellationError {
            return finished(ToolCallResult(status: .notCalled, text: ToolResultText.notRun))
        } catch {
            // Nothing was sent, so nothing can have partly run.
            return finished(ToolCallResult(status: .notCalled, text: ToolResultText.notCalled(Self.summary(error))))
        }
        do {
            let raw = try await client.callTool(binding.tool, arguments: arguments, timeout: timeout)
            return finished(ToolResultProjection.project(result: raw, maxCharacters: maxCharacters))
        } catch is CancellationError {
            return finished(ToolCallResult(status: .cancelled, text: ToolResultText.interrupted))
        } catch let error as MCPError {
            switch error {
            case .needsAuthorization(status: 401), .insufficientScope, .oauth:
                // Refused, or never sent, so nothing ran.
                await authorizationFailed(serverID: binding.serverID, client: client, error: error)
                return finished(ToolCallResult(status: .notCalled, text: ToolResultText.notCalled(Self.summary(error))))
            case .timedOut:
                return finished(ToolCallResult(status: .timedOut, text: ToolResultText.timedOut(seconds: timeout)))
            case .exited:
                return finished(ToolCallResult(status: .failed, text: ToolResultText.crashed))
            case .streamEnded:
                // Never re-issued: that could repeat a side effect without approval.
                return finished(ToolCallResult(status: .failed, text: ToolResultText.failed(
                    "The connection broke before the answer arrived. The tool may or may not have run.")))
            default:
                return finished(ToolCallResult(status: .failed, text: ToolResultText.failed(Self.summary(error))))
            }
        } catch {
            return finished(ToolCallResult(status: .failed, text: ToolResultText.failed(Self.summary(error))))
        }
    }

    public func connect(_ server: MCPServerConfig) async -> MCPServerSnapshot {
        guard server.isEnabled, !forgotten.contains(server.id) else { return snapshot(of: server.id) }
        let connection = connection(for: server)
        connection.stoppedByUser = false
        await stopRunning(connection)
        do {
            _ = try await client(for: server)
        } catch {
            // The state already says what went wrong.
        }
        return snapshot(of: server.id)
    }

    public func stop(serverID: UUID) async {
        guard let connection = connections[serverID] else { return }
        connection.stoppedByUser = true
        await stopRunning(connection)
    }

    public func forget(serverID: UUID) async {
        forgotten.insert(serverID)
        signIns[serverID]?.cancel()
        let connection = connections.removeValue(forKey: serverID)
        connection?.stoppedByUser = true
        let transport = connection.flatMap(detach)
        if let connection { publish(connection) }
        // Before anything is awaited on the network: a refresh or a sign-in in the browser must not
        // bring the token back. Best effort, as there is no one left to tell.
        try? await broker(for: serverID).clear(includingClients: true)
        brokers[serverID] = nil
        await transport?.close(grace: stopGrace)
        connection?.log.clear()
    }

    public func logs(serverID: UUID) async -> [String] {
        connections[serverID]?.log.snapshot() ?? []
    }

    // MARK: Sign-in

    private func broker(for serverID: UUID) -> MCPOAuthBroker {
        if let broker = brokers[serverID] { return broker }
        let broker = MCPOAuthBroker(serverID: serverID, store: oauthStore, quitting: quitting)
        brokers[serverID] = broker
        Task { await broker.setObserver { [weak self] need in
            guard let self else { return }
            Task { await self.signInNeedChanged(serverID: serverID, need: need) }
        } }
        return broker
    }

    private func signInNeedChanged(serverID: UUID, need: MCPSignInNeed?) {
        guard let connection = connections[serverID], let need else { return }
        connection.signInNeed = need
        publish(connection)
    }

    public func signIn(_ server: MCPServerConfig, approve: @escaping MCPOAuthApprove, open: @escaping MCPOAuthOpen,
                       willSignIn: @escaping MCPOAuthWillSignIn) async throws {
        guard server.kind == MCPServerConfig.kindHTTP, !forgotten.contains(server.id) else { throw MCPError.notConfigured }
        guard server.isEnabled else { throw MCPError.disabled }
        let store = self.secrets
        let id = server.id
        let secrets: MCPServerSecrets
        do {
            secrets = try await Task.detached { try store.secrets(for: id) }.value
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.secrets("Could not read this server's secrets from the Keychain: \(SystemErrorText.english(error))")
        }
        let url = try MCPHTTPTransport.validated(url: secrets.url, secrets: secrets)
        let flow = MCPOAuthSignIn(
            serverID: id, server: url, secrets: secrets, broker: broker(for: id), store: oauthStore, approve: approve, open: open,
            willSignIn: willSignIn, probe: { [clientVersion] in try await Self.probe(url: url, secrets: secrets, clientVersion: clientVersion) })
        signIns[id]?.cancel()
        let task = Task { try await flow.run() }
        signIns[id] = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if signIns[id] == task { signIns[id] = nil }
            throw Self.signInError(error)
        }
        if signIns[id] == task { signIns[id] = nil }
    }

    private static func signInError(_ error: Error) -> Error {
        switch error {
        case let failure as MCPOAuthFailure: return MCPError.oauth(failure)
        case is CancellationError: return MCPError.oauth(.cancelled)
        case is MCPError: return error
        default: return MCPError.oauth(.unreachable)
        }
    }

    /// What the server asks for, from one tokenless `initialize` with the server's own static headers.
    private static func probe(url: URL, secrets: MCPServerSecrets, clientVersion: String) async throws -> MCPOAuthChallenge? {
        let transport = MCPHTTPTransport(url: url, headers: secrets.headers, registry: nil)
        let params: JSONValue = .object([
            "protocolVersion": .string(MCPProtocol.legacyVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Parley"), "version": .string(clientVersion)]),
        ])
        do {
            let challenge = try await transport.probe(MCPOutbound(id: 1, method: "initialize", params: params))
            await transport.close(grace: 1)
            return challenge
        } catch is CancellationError {
            await transport.close(grace: 1)
            throw CancellationError()
        } catch {
            await transport.close(grace: 1)
            return nil
        }
    }

    public func signOut(serverID: UUID) async throws {
        signIns[serverID]?.cancel()
        // No await before this, so a Connect queued behind Sign Out comes after it, whole.
        let connection = connections[serverID]
        connection?.stoppedByUser = true
        let transport = connection.flatMap(detach)
        if let connection { publish(connection) }
        // The transport keeps the token it last used, for the session's DELETE.
        var failure: Error?
        do {
            try await broker(for: serverID).clear(includingClients: false)
        } catch {
            failure = error
        }
        await transport?.close(grace: stopGrace)
        if let failure { throw failure }
    }

    public func forgetSignIn(serverID: UUID) async {
        signIns[serverID]?.cancel()
        try? await broker(for: serverID).clear(includingClients: false)
    }

    public func signInInfo(serverID: UUID) async -> MCPSignInInfo? {
        await broker(for: serverID).info
    }

    /// A request on a server that may sign in was refused. A dead token leaves nothing to keep open:
    /// the connection goes, so the state says what to do. This is not a crash. A scope too narrow
    /// leaves it open, because the other tools still work. `client` is the one that was refused: a
    /// late failure on a replaced connection says nothing about the new one.
    private func authorizationFailed(serverID: UUID, client: MCPClient?, error: Error) async {
        guard let connection = connections[serverID], connection.usesSignIn, connection.client === client else { return }
        switch error {
        case MCPError.insufficientScope:
            connection.signInNeed = .moreAccess
            publish(connection)
        case MCPError.needsAuthorization(status: 401):
            let transport = detach(connection)
            connection.signInNeed = .signIn
            connection.state = .failed(Self.describe(error))
            connection.stateSummary = Self.summary(error)
            connection.startError = error
            publish(connection)
            await transport?.close(grace: stopGrace)
        default:
            break
        }
    }

    public func clearLogs(serverIDs: [UUID]) async {
        for id in serverIDs {
            guard let connection = connections[id] else { continue }
            connection.log.clear()
            connection.startError = (connection.startError as? MCPError)?.withoutLog ?? connection.startError
            guard let summary = connection.stateSummary else { continue }
            connection.stateSummary = nil
            switch connection.state {
            case .failed: connection.state = .failed(summary)
            case .restarting: connection.state = .restarting(reason: summary)
            default: continue
            }
            publish(connection)
        }
    }

    public nonisolated func shutdownSync(grace: TimeInterval) {
        quitting.set()
        registry.shutdown(grace: grace)
        // Final: AppState's drain task ends with this.
        updatesContinuation.finish()
    }

    // MARK: Connections

    private func connection(for server: MCPServerConfig) -> Connection {
        if let existing = connections[server.id] {
            // A saved edit replaces a running connection; other changes (names, toggles) do not.
            if existing.config.connectionFingerprint != server.connectionFingerprint {
                let transport = detach(existing)
                existing.isModern = false
                if let transport {
                    let grace = stopGrace
                    Task.detached { await transport.close(grace: grace) }
                }
            }
            existing.config = server
            return existing
        }
        let created = Connection(config: server, log: MCPLogBuffer())
        connections[server.id] = created
        return created
    }

    /// Everything running on `connection` stops counting; the caller closes the transport.
    private func detach(_ connection: Connection) -> MCPTransport? {
        connection.generation += 1
        connection.startTask?.cancel()
        connection.startTask = nil
        connection.startError = MCPError.streamEnded
        connection.crashes = []
        connection.crashedOut = false
        connection.client = nil
        connection.tools = nil
        connection.freshUntil = nil
        connection.justListed = false
        connection.signInNeed = .none
        connection.state = .stopped
        connection.stateSummary = nil
        let transport = connection.transport
        connection.transport = nil
        transport?.onClosed = nil
        return transport
    }

    private func stopRunning(_ connection: Connection) async {
        let transport = detach(connection)
        publish(connection)
        await transport?.close(grace: stopGrace)
    }

    /// The ready client, starting the server if needed. Concurrent callers share one start. The
    /// start is not tied to any caller: Stop ends the wait at once, while a slow first `npx`
    /// download carries on.
    private func client(for server: MCPServerConfig) async throws -> MCPClient {
        guard server.isEnabled else { throw MCPError.disabled }
        guard !forgotten.contains(server.id) else { throw MCPError.notConfigured }
        let connection = connection(for: server)
        if let client = connection.client { return client }
        if connection.crashedOut { throw MCPError.tooManyCrashes(limit: Self.crashLimit) }
        if connection.startTask == nil { begin(connection) }
        let generation = connection.generation
        while connection.startTask != nil, connection.generation == generation {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let client = connection.client { return client }
        throw connection.startError ?? MCPError.streamEnded
    }

    private func begin(_ connection: Connection) {
        // A late `closed` from the last attempt must not touch this one.
        connection.generation += 1
        let generation = connection.generation
        connection.startError = nil
        connection.closeError = nil
        connection.signInNeed = .none
        if case .restarting = connection.state {} else {
            connection.state = .starting
        }
        publish(connection)
        connection.startTask = Task { await self.start(connection, generation: generation) }
    }

    private func start(_ connection: Connection, generation: Int) async {
        let config = connection.config
        var transport: MCPTransport?
        do {
            let opened = try await makeTransport(config, connection: connection)
            transport = opened
            guard connection.generation == generation else { throw CancellationError() }
            connection.transport = opened
            let client = MCPClient(transport: opened, clientVersion: clientVersion, startupTimeout: config.effectiveStartupTimeout)
            opened.onClosed = { [weak self] error in
                guard let self else { return }
                Task { await self.closed(connection, generation: generation, error: error) }
            }
            try await opened.start()
            try await client.connect(preferModern: connection.isModern)
            let list = try await client.listTools()
            guard connection.generation == generation else { throw CancellationError() }
            // It went away just as the list arrived: `closed` left that for this start to report.
            guard connection.transport === opened else { throw connection.closeError ?? MCPError.streamEnded }
            connection.isModern = client.era == .modern
            connection.client = client
            store(list, in: connection)
            connection.justListed = true
            connection.state = .ready
            connection.stateSummary = nil
            connection.startTask = nil
            publish(connection)
        } catch {
            guard connection.generation == generation else {
                // Replaced or stopped in the meantime. What it had opened is this start's to close.
                await transport?.close(grace: stopGrace)
                return
            }
            let shown: Error
            if case MCPError.timedOut(let seconds) = error {
                shown = MCPError.startupTimedOut(seconds: seconds, stderrTail: connection.log.tail(5))
            } else {
                shown = error
            }
            connection.startError = shown
            connection.state = .failed(Self.describe(shown))
            connection.stateSummary = Self.summary(shown)
            if connection.usesSignIn {
                if case MCPError.needsAuthorization(status: 401) = shown { connection.signInNeed = .signIn }
                if case MCPError.insufficientScope = shown { connection.signInNeed = .moreAccess }
            }
            connection.transport = nil
            connection.startTask = nil
            transport?.onClosed = nil
            publish(connection)
            await transport?.close(grace: stopGrace)
        }
    }

    private func makeTransport(_ config: MCPServerConfig, connection: Connection) async throws -> MCPTransport {
        let log = connection.log
        let secrets: MCPServerSecrets
        do {
            // Off the actor: the Keychain may ask the user, and other servers must not wait for that.
            let store = self.secrets
            let id = config.id
            secrets = try await Task.detached { try store.secrets(for: id) }.value
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.secrets("Could not read this server's secrets from the Keychain: \(SystemErrorText.english(error))")
        }
        switch config.kind {
        case MCPServerConfig.kindStdio:
            let directory = config.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let resolved = try await pathResolver.resolve(config.command, overridePATH: secrets.env["PATH"], relativeTo: directory)
            let launch = MCPStdioTransport.Launch(
                executable: resolved.executable, arguments: secrets.args,
                environment: ShellPATHResolver.childEnvironment(path: resolved.path, server: secrets.env), directory: directory)
            return MCPStdioTransport(launch: launch, log: log, registry: registry)
        case MCPServerConfig.kindHTTP:
            let url = try MCPHTTPTransport.validated(url: secrets.url, secrets: secrets)
            connection.usesSignIn = !secrets.usesStaticAuthorization && MCPOAuthPolicy.serverMaySignIn(url)
            guard connection.usesSignIn else { return MCPHTTPTransport(url: url, headers: secrets.headers, registry: registry) }
            let broker = broker(for: config.id)
            do {
                try await broker.attach(serverURL: url)
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.secrets("Could not read this server's sign-in from the Keychain: \(SystemErrorText.english(error))")
            }
            return MCPHTTPTransport(url: url, headers: secrets.headers, registry: registry, authorizer: broker)
        default:
            throw MCPError.unknownKind(config.kind)
        }
    }

    /// The server went away by itself. The next use restarts it, unless this keeps happening.
    private func closed(_ connection: Connection, generation: Int, error: Error?) {
        guard connection.generation == generation else { return }
        // A start in progress reports this itself.
        let wasReady = connection.client != nil
        connection.client = nil
        connection.transport = nil
        guard wasReady else {
            connection.closeError = error
            return
        }
        connection.tools = nil
        connection.freshUntil = nil
        connection.generation += 1
        let now = Date()
        connection.crashes = connection.crashes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
        if connection.crashes.count >= Self.crashLimit {
            connection.crashedOut = true
            connection.state = .failed(Self.describe(MCPError.tooManyCrashes(limit: Self.crashLimit)))
        } else {
            connection.state = .restarting(reason: error.map(Self.describe) ?? "The server stopped.")
            connection.stateSummary = error.map(Self.summary)
        }
        publish(connection)
    }

    // MARK: Status

    private func publish(_ connection: Connection) {
        updatesContinuation.yield(snapshot(of: connection))
    }

    private func snapshot(of id: UUID) -> MCPServerSnapshot {
        connections[id].map(snapshot(of:)) ?? MCPServerSnapshot(serverID: id)
    }

    private func snapshot(of connection: Connection) -> MCPServerSnapshot {
        MCPServerSnapshot(serverID: connection.config.id, state: connection.state,
                          protocolVersion: connection.client?.protocolVersion, serverInfo: connection.client?.serverInfo,
                          tools: connection.tools?.tools ?? [], hiddenTools: connection.tools?.hidden ?? [],
                          isRunning: connection.client != nil, signInNeed: connection.signInNeed)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// What may be saved or sent to the model (MCPError.summary).
    /// Fixed English: a URLError from the transport (an unreachable server) would otherwise bring
    /// Foundation's text in the interface language into tool results and saved notes.
    private static func summary(_ error: Error) -> String {
        (error as? MCPError)?.summary ?? SystemErrorText.english(error)
    }
}
