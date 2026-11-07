import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Sign-in on the app side: what Save, Delete and Sign In do around the connection manager.

private final class SignInHost: MCPToolHost, @unchecked Sendable {
    private let lock = NSLock()
    private var signOuts: [UUID] = []
    private var signIns: [UUID] = []
    private var forgottenSignIns: [UUID] = []
    private var connected: [MCPServerConfig] = []
    var failure: Error?
    /// What the browser's minutes hold: runs after the token is accepted.
    var duringSignIn: (@Sendable () async -> Void)?
    let updates: AsyncStream<MCPServerSnapshot>

    init() {
        (updates, _) = AsyncStream.makeStream(of: MCPServerSnapshot.self)
    }

    var signedOut: [UUID] { lock.withLock { signOuts } }
    var signedIn: [UUID] { lock.withLock { signIns } }
    var signInsForgotten: [UUID] { lock.withLock { forgottenSignIns } }
    var connects: [MCPServerConfig] { lock.withLock { connected } }

    func catalog(for servers: [MCPServerConfig]) async -> MCPToolCatalog { MCPToolCatalog() }
    func call(_ binding: MCPToolBinding, arguments: [String: JSONValue], timeout: TimeInterval, maxCharacters: Int) async -> ToolCallResult {
        ToolCallResult(status: .failed, text: "")
    }
    func connect(_ server: MCPServerConfig) async -> MCPServerSnapshot {
        lock.withLock { connected.append(server) }
        return MCPServerSnapshot(serverID: server.id)
    }
    func stop(serverID: UUID) async {}
    func forget(serverID: UUID) async {}
    func logs(serverID: UUID) async -> [String] { [] }
    func clearLogs(serverIDs: [UUID]) async {}
    func shutdownSync(grace: TimeInterval) {}

    func signIn(_ server: MCPServerConfig, approve: @escaping MCPOAuthApprove, open: @escaping MCPOAuthOpen,
                willSignIn: @escaping MCPOAuthWillSignIn) async throws {
        if let failure { throw failure }
        await duringSignIn?()
        await willSignIn()
        lock.withLock { signIns.append(server.id) }
    }

    func forgetSignIn(serverID: UUID) async {
        lock.withLock { forgottenSignIns.append(serverID) }
    }

    func signOut(serverID: UUID) async throws {
        lock.withLock { signOuts.append(serverID) }
    }
}

@MainActor
@Suite struct MCPSignInAppTests {
    private func withState(_ body: (AppState, SignInHost, InMemoryMCPSecretStore) async throws -> Void) async throws {
        let root = try makeTempRoot()
        let suite = defaultsSuiteName(in: root)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeDefaultsSuite(suite, defaults, root: root) }
        let host = SignInHost()
        let store = InMemoryMCPSecretStore()
        let state = AppState(settings: AppSettings(defaults: defaults), mcp: host, mcpSecrets: store)
        try await body(state, host, store)
    }

    private func http(_ url: String, allowed: [String: String] = [:]) -> (MCPServerConfig, MCPServerSecrets) {
        (MCPServerConfig(name: "Remote", kind: MCPServerConfig.kindHTTP, alwaysAllowedTools: allowed), MCPServerSecrets(url: url))
    }

    @Test func aChangedURLEndsTheSignIn() async throws {
        try await withState { state, host, _ in
            let (config, secrets) = http("https://a.example/mcp")
            let saved = try state.saveServer(config, secrets: secrets)
            var moved = secrets
            moved.url = "https://b.example/mcp"
            try state.saveServer(saved, secrets: moved)
            let deadline = Date().addingTimeInterval(3)
            while host.signInsForgotten.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(host.signInsForgotten == [config.id])
            // Not a sign-out, which would stop a Connect pressed right after the save.
            #expect(host.signedOut.isEmpty)
        }
    }

    @Test func otherEditsKeepTheSignIn() async throws {
        try await withState { state, host, _ in
            let (config, secrets) = http("https://a.example/mcp")
            var saved = try state.saveServer(config, secrets: secrets)
            saved.name = "Renamed"
            var edited = secrets
            edited.headers = ["X-Team": "fake"]
            try state.saveServer(saved, secrets: edited)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(host.signInsForgotten.isEmpty)
        }
    }

    @Test func aFirstSaveHasNoSignInToEnd() async throws {
        try await withState { state, host, _ in
            let (config, secrets) = http("https://a.example/mcp")
            try state.saveServer(config, secrets: secrets)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(host.signInsForgotten.isEmpty)
        }
    }

    /// Parley cannot see which account was chosen in the browser.
    @Test func signingInClearsAlwaysAllowForThatServerOnly() async throws {
        try await withState { state, _, _ in
            let (config, secrets) = http("https://a.example/mcp", allowed: ["echo": "print"])
            let (other, otherSecrets) = http("https://b.example/mcp", allowed: ["echo": "print"])
            try state.saveServer(config, secrets: secrets)
            try state.saveServer(other, secrets: otherSecrets)
            try await state.signIn(config.id) { _ in .cancel }
            #expect(state.mcpServer(config.id)?.alwaysAllowedTools.isEmpty == true)
            #expect(state.mcpServer(other.id)?.alwaysAllowedTools == ["echo": "print"])
        }
    }

    @Test func theConnectionUsesTheServerAsItIsWhenTheBrowserIsDone() async throws {
        try await withState { state, host, _ in
            let (config, secrets) = http("https://a.example/mcp")
            let saved = try state.saveServer(config, secrets: secrets)
            host.duringSignIn = { @MainActor [weak state] in
                var off = saved
                off.isEnabled = false
                _ = try? state?.saveServer(off, secrets: secrets)
            }
            try await state.signIn(config.id) { _ in .cancel }
            #expect(host.connects.isEmpty)
        }
    }

    @Test func aFailedSignInKeepsAlwaysAllow() async throws {
        try await withState { state, host, _ in
            let (config, secrets) = http("https://a.example/mcp", allowed: ["echo": "print"])
            try state.saveServer(config, secrets: secrets)
            host.failure = MCPError.oauth(.cancelled)
            await #expect(throws: MCPError.oauth(.cancelled)) { try await state.signIn(config.id) { _ in .cancel } }
            #expect(state.mcpServer(config.id)?.alwaysAllowedTools == ["echo": "print"])
        }
    }

    @Test func signInForAServerThatIsGoneStartsNothing() async throws {
        try await withState { state, host, _ in
            await #expect(throws: MCPError.notConfigured) { try await state.signIn(UUID()) { _ in .cancel } }
            #expect(host.signedIn.isEmpty)
        }
    }

    @Test func theFormKeepsClientDetailsInTheKeychainItem() throws {
        let (config, secrets) = http("https://a.example/mcp")
        var filled = secrets
        filled.oauthClientID = "fake-id"
        filled.oauthClientSecret = "fake-secret"
        filled.oauthCallbackPort = 8123
        let draft = MCPServerDraft(config: config, secrets: filled)
        #expect(draft.oauthCallbackPort == "8123")
        let applied = draft.applied(to: config)
        #expect(applied.secrets == filled)
        let preferences = String(decoding: try JSONEncoder().encode(applied.config), as: UTF8.self)
        #expect(!preferences.contains("fake-id"))
        #expect(!preferences.contains("fake-secret"))
    }

    @Test func aCallbackPortIsChecked() {
        var draft = MCPServerDraft()
        draft.name = "Remote"
        draft.kind = MCPServerConfig.kindHTTP
        draft.url = "https://a.example/mcp"
        #expect(draft.problem == nil)
        for bad in ["80", "70000", "abc", "12.5"] {
            draft.oauthCallbackPort = bad
            #expect(draft.problem?.contains("callback port") == true)
        }
        draft.oauthCallbackPort = "8123"
        #expect(draft.problem == nil)
    }
}
