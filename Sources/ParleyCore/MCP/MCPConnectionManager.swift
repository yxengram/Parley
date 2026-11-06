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

    private static let crashWindow: TimeInterval = 60
    private static let crashLimit = 3
    /// How long each step of stopping a server waits for it (2 s by default; quit passes its own).
    private nonisolated let stopGrace: TimeInterval

    public init(secrets: MCPSecretStore, pathResolver: ShellPATHResolver = ShellPATHResolver(),
                clientVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0",
                stopGrace: TimeInterval = 2) {
        self.secrets = secrets
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
        do {
            connections[server.id]?.stoppedByUser = false
            let client = try await client(for: server)
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
        guard server.isEnabled else { return snapshot(of: server.id) }
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
        guard let connection = connections.removeValue(forKey: serverID) else { return }
        connection.stoppedByUser = true
        await stopRunning(connection)
        connection.log.clear()
    }

    public func logs(serverID: UUID) async -> [String] {
        connections[serverID]?.log.snapshot() ?? []
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
            let opened = try await makeTransport(config, log: connection.log)
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
            connection.transport = nil
            connection.startTask = nil
            transport?.onClosed = nil
            publish(connection)
            await transport?.close(grace: stopGrace)
        }
    }

    private func makeTransport(_ config: MCPServerConfig, log: MCPLogBuffer) async throws -> MCPTransport {
        let secrets: MCPServerSecrets
        do {
            // Off the actor: the Keychain may ask the user, and other servers must not wait for that.
            let store = self.secrets
            let id = config.id
            secrets = try await Task.detached { try store.secrets(for: id) }.value
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.secrets("Could not read this server's secrets from the Keychain: \(error.localizedDescription)")
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
            return MCPHTTPTransport(url: url, headers: secrets.headers, registry: registry)
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
                          isRunning: connection.client != nil)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// What may be saved or sent to the model (MCPError.summary).
    private static func summary(_ error: Error) -> String {
        (error as? MCPError)?.summary ?? describe(error)
    }
}
