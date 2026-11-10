import Foundation

/// The host a session talks to: built-in calls stay here, everything else goes to the real host. The
/// real host never hears of the built-in server, so a conversation with only built-in tools starts
/// nothing, and one with no tools at all makes no call to it either.
public final class BuiltInToolRouter: MCPToolHost, Sendable {
    private let host: MCPToolHost
    private let runner: BuiltInToolRunner

    /// `settings` is read on every call, so a change in Settings applies to the next one. `pageLoader`
    /// is the app's WebKit side of `browse_url`; without one that tool reports it is not available.
    public convenience init(wrapping host: MCPToolHost, settings: @escaping @Sendable () async -> BuiltInToolSettings,
                            pageLoader: BuiltInPageLoader? = nil) {
        self.init(wrapping: host, runner: BuiltInToolRunner(settings: settings, browser: pageLoader.map(BuiltInBrowser.init(loader:))))
    }

    init(wrapping host: MCPToolHost, runner: BuiltInToolRunner) {
        self.host = host
        self.runner = runner
    }

    private static func isBuiltIn(_ id: UUID) -> Bool { id == BuiltInTools.serverID }

    public func catalog(for servers: [MCPServerConfig]) async -> MCPToolCatalog {
        let real = servers.filter { !Self.isBuiltIn($0.id) }
        let listed = real.isEmpty ? MCPToolCatalog() : await host.catalog(for: real)
        guard let config = servers.first(where: { Self.isBuiltIn($0.id) && $0.isEnabled }) else { return listed }
        let own = BuiltInTools.bindings(for: config, avoiding: Set(listed.bindings.map(\.exposedName)))
        return MCPToolCatalog(bindings: listed.bindings + own, unavailable: listed.unavailable)
    }

    public func call(_ binding: MCPToolBinding, arguments: [String: JSONValue], timeout: TimeInterval,
                     maxCharacters: Int) async -> ToolCallResult {
        guard Self.isBuiltIn(binding.serverID) else {
            return await host.call(binding, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters)
        }
        return await runner.call(binding.tool, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters)
    }

    public func connect(_ server: MCPServerConfig) async -> MCPServerSnapshot {
        guard Self.isBuiltIn(server.id) else { return await host.connect(server) }
        return MCPServerSnapshot(serverID: server.id, state: .ready, tools: BuiltInTools.bindings(for: server).map(\.tool), isRunning: true)
    }

    public func stop(serverID: UUID) async {
        if !Self.isBuiltIn(serverID) { await host.stop(serverID: serverID) }
    }

    public func forget(serverID: UUID) async {
        if !Self.isBuiltIn(serverID) { await host.forget(serverID: serverID) }
    }

    public func logs(serverID: UUID) async -> [String] {
        Self.isBuiltIn(serverID) ? [] : await host.logs(serverID: serverID)
    }

    public func clearLogs(serverIDs: [UUID]) async {
        let real = serverIDs.filter { !Self.isBuiltIn($0) }
        if !real.isEmpty { await host.clearLogs(serverIDs: real) }
    }

    public var updates: AsyncStream<MCPServerSnapshot> { host.updates }

    public func shutdownSync(grace: TimeInterval) { host.shutdownSync(grace: grace) }

    public func signIn(_ server: MCPServerConfig, approve: @escaping MCPOAuthApprove, open: @escaping MCPOAuthOpen,
                       willSignIn: @escaping MCPOAuthWillSignIn) async throws {
        try await host.signIn(server, approve: approve, open: open, willSignIn: willSignIn)
    }

    public func signOut(serverID: UUID) async throws { try await host.signOut(serverID: serverID) }

    public func forgetSignIn(serverID: UUID) async { await host.forgetSignIn(serverID: serverID) }

    public func signInInfo(serverID: UUID) async -> MCPSignInInfo? { await host.signInInfo(serverID: serverID) }
}
