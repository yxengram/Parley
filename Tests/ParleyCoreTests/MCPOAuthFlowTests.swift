import Foundation
import Testing
@testable import ParleyCore

// The whole of sign-in against tools/mock_mcp_server.py, which is also its authorization server. A
// scripted browser follows the mock's redirects, as the system browser would. Fake values only.

private final class SignInScript: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [MCPOAuthReview] = []
    private var pages: [URL] = []
    var answer: @Sendable (MCPOAuthReview) -> MCPOAuthAnswer = { _ in .proceed(host: nil) }
    /// Sent to the listener before the real page, as a stray page in the browser would.
    var strayRequest: (@Sendable (URLComponents) -> URL?)?
    var opens = true
    /// `open` returns only after the whole redirect: a provider with a live session is that quick.
    var answersBeforeOpenReturns = false

    var reviews: [MCPOAuthReview] { lock.withLock { seen } }
    var opened: [URL] { lock.withLock { pages } }

    private func note(_ review: MCPOAuthReview) {
        lock.withLock { seen.append(review) }
    }

    private func note(_ url: URL) {
        lock.withLock { pages.append(url) }
    }

    var approve: MCPOAuthApprove {
        { [self] review in
            note(review)
            return answer(review)
        }
    }

    var open: MCPOAuthOpen {
        { [self] url in
            note(url)
            guard opens else { return false }
            if answersBeforeOpenReturns {
                _ = try? await URLSession(configuration: .ephemeral).data(from: url)
                return true
            }
            let stray = strayRequest
            Task.detached {
                let session = URLSession(configuration: .ephemeral)
                if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let wrong = stray?(parts) {
                    _ = try? await session.data(from: wrong)
                }
                _ = try? await session.data(from: url)
            }
            return true
        }
    }
}

private func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

extension MCPHTTPHarness {
    /// (HTTP method, path, headers, body) of everything received.
    fileprivate func contacts() async throws -> [(http: String, path: String, headers: [String: String], body: [String: Any])] {
        try await log().compactMap { entry in
            guard let http = entry["http"] as? String else { return nil }
            return (http, entry["path"] as? String ?? "", entry["headers"] as? [String: String] ?? [:], entry["body"] as? [String: Any] ?? [:])
        }
    }

    fileprivate func paths() async throws -> [String] {
        try await contacts().map { "\($0.http) \($0.path.split(separator: "?").first.map(String.init) ?? $0.path)" }
    }

    fileprivate func expireTokens() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mock/expire-tokens")!)
        request.httpMethod = "POST"
        _ = try await URLSession(configuration: .ephemeral).data(for: request)
    }

    /// As AppState does it: sign in, then connect.
    fileprivate func signIn(_ script: SignInScript) async throws {
        try await manager.signIn(config, approve: script.approve, open: script.open, willSignIn: {})
        _ = await manager.connect(config)
    }

    fileprivate func failure(signingInWith script: SignInScript) async -> MCPError? {
        do {
            try await signIn(script)
            return nil
        } catch {
            return error as? MCPError
        }
    }

    fileprivate func storedToken() throws -> MCPOAuthTokens {
        try #require(try oauthStore.tokens(for: config.id))
    }
}

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPOAuthFlowTests {
    private let wellKnown = ["GET /.well-known/oauth-protected-resource/mcp", "GET /.well-known/oauth-authorization-server"]

    private func withServer(era: String = "legacy", _ behaviors: [String] = [], headers: [String: String] = [:], other: Int? = nil,
                            _ body: (MCPHTTPHarness) async throws -> Void) async throws {
        var environment: [String: String] = [:]
        if let other { environment["MOCK_OTHER_PORT"] = String(other) }
        let harness = try await MCPHTTPHarness(era: era, behaviors: ["oauth"] + behaviors, headers: headers, environment: environment)
        defer { harness.finish() }
        try await body(harness)
    }

    /// Sign-in to a tool call to a refresh, and a tool call again: the flow this feature exists for.
    @Test func signInToolCallRefreshToolCall() async throws {
        try await withServer { harness in
            let before = await harness.manager.connect(harness.config)
            #expect(before.signInNeed == .signIn)
            if case .failed(let message) = before.state {
                #expect(message == MCPError.needsAuthorization(status: 401).errorDescription)
            } else {
                Issue.record("expected a failed state")
            }
            // A 401 stops there: nothing was looked up.
            #expect(try await harness.paths() == ["POST /mcp"])

            let script = SignInScript()
            try await harness.signIn(script)

            let first = try await harness.call("echo", ["text": .string("hello")])
            #expect(first.text == "hello")
            let signedIn = try harness.storedToken()
            #expect(signedIn.scopes.contains("files:read"))
            #expect(signedIn.scopes.contains("offline_access"))

            try await harness.expireTokens()
            let second = try await harness.call("echo", ["text": .string("again")])
            #expect(second.text == "again")

            let renewed = try harness.storedToken()
            #expect(renewed.accessToken != signedIn.accessToken)
            #expect(renewed.refreshToken != signedIn.refreshToken)
            #expect(renewed.refreshToken != nil)

            let contacts = try await harness.contacts()
            let tokenCalls = contacts.filter { $0.path == "/token" }
            #expect(tokenCalls.map { $0.body["grant_type"] as? String } == ["authorization_code", "refresh_token"])
            #expect(tokenCalls.allSatisfy { $0.body["resource"] as? String == harness.url })
            #expect(tokenCalls[1].body["refresh_token"] as? String == signedIn.refreshToken)
            #expect(contacts.filter { $0.path == "/register" }.count == 1)

            // Every request after sign-in carries a token, notifications included.
            let afterSignIn = contacts.drop { $0.path != "/token" }.filter { $0.path == "/mcp" }
            try #require(!afterSignIn.isEmpty)
            #expect(afterSignIn.allSatisfy { $0.headers["authorization"]?.hasPrefix("Bearer ") == true })
            #expect(afterSignIn.contains { ($0.body["method"] as? String) == "notifications/initialized" })
        }
    }

    @Test func theExactRequestsOfASignIn() async throws {
        try await withServer { harness in
            let script = SignInScript()
            try await harness.signIn(script)
            #expect(Array(try await harness.paths().prefix(6)) == [
                "POST /mcp", // the tokenless probe
                wellKnown[0], wellKnown[1],
                "POST /register", "GET /authorize", "POST /token",
            ])
            // Nothing but these, ever: no jwks, no userinfo, no logo, no revocation.
            let others = Set(try await harness.paths()).subtracting(["POST /mcp", "DELETE /mcp", "POST /register", "GET /authorize", "POST /token"] + wellKnown)
            #expect(others.isEmpty)
        }
    }

    @Test func theAuthorizationRequestIsWhatTheSpecAsksFor() async throws {
        try await withServer { harness in
            let script = SignInScript()
            try await harness.signIn(script)
            let page = try #require(script.opened.first)
            #expect(page.absoluteString.hasPrefix("http://127.0.0.1:\(harness.port)/authorize?"))
            #expect(query(page, "response_type") == "code")
            #expect(query(page, "code_challenge_method") == "S256")
            #expect(query(page, "resource") == harness.url)
            #expect(query(page, "scope") == "files:read offline_access")
            let redirect = try #require(query(page, "redirect_uri"))
            #expect(redirect.hasPrefix("http://127.0.0.1:"))
            #expect(redirect.hasSuffix("/callback"))
            #expect(query(page, "state")?.count == 43)
            #expect(query(page, "code_challenge")?.count == 43)
        }
    }

    @Test func theSheetComesBeforeAnythingElseIsContacted() async throws {
        try await withServer { harness in
            let script = SignInScript()
            script.answer = { _ in .cancel }
            let failure = await harness.failure(signingInWith: script)
            #expect(failure == .oauth(.cancelled))
            #expect(try await harness.paths() == ["POST /mcp", wellKnown[0]])
            #expect(script.opened.isEmpty)
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
            let review = try #require(script.reviews.first)
            #expect(review.kind == .provider)
            #expect(review.hosts == ["http://127.0.0.1:\(harness.port)"])
            #expect(review.scopes == ["files:read"])
            #expect(review.providerDiffers == false)
        }
    }

    @Test func aRememberedChallengeNeedsNoProbe() async throws {
        try await withServer { harness in
            _ = await harness.manager.connect(harness.config)
            try await harness.signIn(SignInScript())
            let posts = try await harness.paths().prefix(3)
            #expect(Array(posts) == ["POST /mcp", wellKnown[0], wellKnown[1]])
        }
    }

    @Test func noChallengeHeaderFallsBackToTheRoot() async throws {
        try await withServer(["oauth-no-header", "oauth-root-metadata"]) { harness in
            try await harness.signIn(SignInScript())
            #expect(try harness.storedToken().resource == "http://127.0.0.1:\(harness.port)")
            let paths = try await harness.paths()
            #expect(paths.contains("GET /.well-known/oauth-protected-resource/mcp"))
            #expect(paths.contains("GET /.well-known/oauth-protected-resource"))
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
        }
    }

    @Test func aModernOnlyServersChallengeIsNotLost() async throws {
        try await withServer(era: "modern") { harness in
            let state = await harness.manager.connect(harness.config)
            #expect(state.signInNeed == .signIn)
            try await harness.signIn(SignInScript())
            #expect(try await harness.call("echo", ["text": .string("modern")]).text == "modern")
        }
    }

    // MARK: Hostile answers

    private func refuses(_ behaviors: [String], _ expected: MCPOAuthFailure) async throws {
        try await withServer(behaviors) { harness in
            let script = SignInScript()
            let failure = await harness.failure(signingInWith: script)
            #expect(failure == .oauth(expected))
            try #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
        }
    }

    @Test func wrongIssuerInMetadataIsRefusedBeforeTheBrowser() async throws {
        try await withServer(["oauth-wrong-issuer"]) { harness in
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.issuerMismatch))
            #expect(script.opened.isEmpty)
            try await #expect(!(try await harness.paths().contains("POST /register")))
        }
    }

    @Test func noPKCEIsRefusedBeforeTheBrowser() async throws {
        try await withServer(["oauth-no-s256"]) { harness in
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.noPKCE))
            #expect(script.opened.isEmpty)
        }
    }

    @Test func wrongResourceIsRefused() async throws {
        try await refuses(["oauth-wrong-resource"], .resourceMismatch)
    }

    @Test func aPlainHTTPEndpointIsRefusedWithoutContact() async throws {
        try await refuses(["oauth-plain-endpoint"], .hostRefused("example.invalid"))
    }

    @Test func wrongIssInTheCallbackDiscardsTheCode() async throws {
        try await withServer(["oauth-wrong-iss"]) { harness in
            #expect(await harness.failure(signingInWith: SignInScript()) == .oauth(.responseMismatch))
            try await #expect(!(try await harness.paths().contains("POST /token")))
        }
    }

    @Test func aMissingIssIsRefusedWhenMetadataPromisedIt() async throws {
        try await withServer(["oauth-no-iss"]) { harness in
            #expect(await harness.failure(signingInWith: SignInScript()) == .oauth(.responseMismatch))
            try await #expect(!(try await harness.paths().contains("POST /token")))
        }
    }

    @Test func aDenialShowsOnlyItsCode() async throws {
        try await withServer(["oauth-denied"]) { harness in
            let failure = await harness.failure(signingInWith: SignInScript())
            #expect(failure == .oauth(.denied("access_denied")))
            #expect(failure?.errorDescription?.contains("fake-secret-description") == false)
        }
    }

    @Test func aStrayRequestWithTheWrongStateChangesNothing() async throws {
        try await withServer { harness in
            let script = SignInScript()
            script.strayRequest = { parts in
                guard let redirect = parts.queryItems?.first(where: { $0.name == "redirect_uri" })?.value else { return nil }
                return URL(string: redirect + "?state=forged&code=forged-code")
            }
            try await harness.signIn(script)
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
            let codes = try await harness.contacts().filter { $0.path == "/token" }.compactMap { $0.body["code"] as? String }
            #expect(codes.count == 1)
            #expect(!codes.contains("forged-code"))
        }
    }

    @Test func aBrowserThatCannotOpen() async throws {
        try await withServer { harness in
            let script = SignInScript()
            script.opens = false
            #expect(await harness.failure(signingInWith: script) == .oauth(.browserFailed))
        }
    }

    @Test func anotherHostsMetadataIsAskedAboutFirst() async throws {
        let other = try await MCPHTTPHarness(behaviors: [])
        defer { other.finish() }
        try await withServer(["oauth-other-metadata"], other: other.port) { harness in
            let script = SignInScript()
            script.answer = { _ in .cancel }
            #expect(await harness.failure(signingInWith: script) == .oauth(.cancelled))
            let review = try #require(script.reviews.first)
            #expect(review.kind == .metadataHost)
            #expect(review.hosts == ["127.0.0.1:\(other.port)"])
            #expect(try await other.requests().isEmpty)
        }
    }

    @Test func aProviderOnAnotherHostIsNamedAndWarnedAbout() async throws {
        let other = try await MCPHTTPHarness(behaviors: [])
        defer { other.finish() }
        try await withServer(["oauth-other-issuer"], other: other.port) { harness in
            let script = SignInScript()
            script.answer = { _ in .cancel }
            #expect(await harness.failure(signingInWith: script) == .oauth(.cancelled))
            let review = try #require(script.reviews.first)
            #expect(review.providerDiffers)
            #expect(review.hosts == ["http://127.0.0.1:\(other.port)"])
            #expect(try await other.requests().isEmpty)
        }
    }

    @Test func aFurtherHostInMetadataIsAskedAboutBeforeItGetsAnything() async throws {
        let other = try await MCPHTTPHarness(behaviors: [])
        defer { other.finish() }
        try await withServer(["oauth-other-token"], other: other.port) { harness in
            let script = SignInScript()
            script.answer = { review in review.kind == .moreHosts ? .cancel : .proceed(host: nil) }
            #expect(await harness.failure(signingInWith: script) == .oauth(.cancelled))
            let further = try #require(script.reviews.last)
            #expect(further.kind == .moreHosts)
            #expect(further.hosts == ["localhost:\(other.port)"])
            #expect(script.opened.isEmpty)
            #expect(try await other.requests().isEmpty)
            #expect(!(try await harness.paths().contains("POST /register")))
        }
    }

    // MARK: What refused servers can do

    @Test func aPlainHTTPServerOffThisMacCannotSignIn() async throws {
        let store = InMemoryMCPSecretStore()
        let oauth = InMemoryMCPOAuthStore()
        let manager = MCPConnectionManager(secrets: store, oauthStore: oauth, pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "lan", kind: MCPServerConfig.kindHTTP)
        try store.setSecrets(MCPServerSecrets(url: "http://192.0.2.1/mcp"), for: config.id)
        await #expect(throws: MCPError.oauth(.insecureServer)) {
            try await manager.signIn(config, approve: SignInScript().approve, open: SignInScript().open, willSignIn: {})
        }
    }

    @Test func aURLWithCredentialsCannotSignIn() async throws {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, oauthStore: InMemoryMCPOAuthStore(), pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "x", kind: MCPServerConfig.kindHTTP)
        try store.setSecrets(MCPServerSecrets(url: "https://user:fake-pw@mcp.example.invalid/mcp"), for: config.id)
        await #expect(throws: MCPError.oauth(.urlHasCredentials)) {
            try await manager.signIn(config, approve: SignInScript().approve, open: SignInScript().open, willSignIn: {})
        }
    }

    // MARK: Static headers

    @Test func aStaticAuthorizationHeaderMeansNoSignIn() async throws {
        try await withServer(headers: ["Authorization": "Bearer fake-static", "X-Team": "fake-team"]) { harness in
            #expect(await harness.failure(signingInWith: SignInScript()) == .oauth(.staticAuthorization))
            try await #expect(try await harness.paths().isEmpty)
            let state = await harness.manager.connect(harness.config)
            // The mock wants a real token: this is the server's 401, with no sign-in offered.
            #expect(state.signInNeed == .none)
            try await #expect(try await harness.contacts().allSatisfy { $0.headers["authorization"] == "Bearer fake-static" })
            if case .failed(let message) = state.state {
                // This server has no Sign In button to point at.
                #expect(message == MCPError.credentialsRefused(status: 401).errorDescription)
            } else {
                Issue.record("expected a failed state")
            }
        }
    }

    @Test func otherStaticHeadersGoToTheServerAndNeverToTheProvider() async throws {
        try await withServer(headers: ["X-Team": "fake-team"]) { harness in
            try await harness.signIn(SignInScript())
            _ = try await harness.call("echo", ["text": .string("x")])
            let contacts = try await harness.contacts()
            let server = contacts.filter { $0.path == "/mcp" }
            let provider = contacts.filter { $0.path != "/mcp" && !$0.path.hasPrefix("/.well-known/oauth-protected-resource") }
            try #require(!provider.isEmpty)
            #expect(server.allSatisfy { $0.headers["x-team"] == "fake-team" })
            #expect(provider.allSatisfy { $0.headers["x-team"] == nil })
            #expect(provider.filter { $0.path != "/token" }.allSatisfy { $0.headers["authorization"] == nil })
        }
    }

    // MARK: Refresh

    @Test func aTokenNearItsEndIsRenewedBeforeUse() async throws {
        try await withServer(["oauth-short-lived"]) { harness in
            try await harness.signIn(SignInScript())
            let before = try harness.storedToken()
            _ = try await harness.call("echo", ["text": .string("x")])
            #expect(try harness.storedToken().accessToken != before.accessToken)
            let refreshes = try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }
            #expect(refreshes.count >= 1)
        }
    }

    @Test func aProviderThatDoesNotRotateKeepsItsRefreshToken() async throws {
        try await withServer(["oauth-keep-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let before = try harness.storedToken()
            try await harness.expireTokens()
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
            #expect(try harness.storedToken().refreshToken == before.refreshToken)
            #expect(try harness.storedToken().accessToken != before.accessToken)
        }
    }

    @Test func noExpiryMeansUseUntilA401() async throws {
        try await withServer(["oauth-no-expiry"]) { harness in
            try await harness.signIn(SignInScript())
            #expect(try harness.storedToken().expiresAt == nil)
            _ = try await harness.call("echo", ["text": .string("x")])
            _ = try await harness.call("echo", ["text": .string("y")])
            #expect(try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }.isEmpty)
        }
    }

    @Test func withoutARefreshTokenA401GoesStraightToSignIn() async throws {
        try await withServer(["oauth-no-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
            #expect(result.status == ToolCallStatus.notCalled.rawValue)
            #expect(result.text.contains("sign in"))
            #expect(await harness.manager.connect(harness.config).signInNeed == .signIn)
            #expect(try await harness.contacts().filter { $0.path == "/token" }.count == 1)
        }
    }

    @Test func invalidGrantEndsTheSignInAndItsConnection() async throws {
        try await withServer(["oauth-invalid-grant"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
            #expect(result.status == ToolCallStatus.notCalled.rawValue)
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
            // The registration stays: a new Sign In leaves no second record at the provider.
            #expect(try harness.oauthStore.clients(for: harness.config.id).count == 1)
        }
    }

    @Test func invalidClientDropsTheRegistrationToo() async throws {
        try await withServer(["oauth-invalid-client"]) { harness in
            try await harness.signIn(SignInScript())
            _ = await harness.catalog()
            try await harness.expireTokens()
            _ = await harness.catalog()
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
            #expect(try harness.oauthStore.clients(for: harness.config.id).isEmpty)
        }
    }

    @Test func aProviderOutageKeepsTheSignIn() async throws {
        try await withServer(["oauth-refresh-500"]) { harness in
            try await harness.signIn(SignInScript())
            let before = try harness.storedToken()
            _ = await harness.catalog()
            try await harness.expireTokens()
            let result = await harness.catalog()
            // Not "sign in": nothing is wrong with the sign-in, and the next use tries again.
            #expect(result.unavailable.first?.reason == MCPError.oauth(.refreshFailed).errorDescription)
            #expect(try harness.storedToken() == before)
            #expect(await harness.manager.signInInfo(serverID: harness.config.id) != nil)
        }
    }

    @Test func concurrentUsesShareOneRefresh() async throws {
        try await withServer(["oauth-slow-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            let results = await withTaskGroup(of: ToolCallResult.self, returning: [ToolCallResult].self) { group in
                for index in 0..<4 {
                    group.addTask { await harness.manager.call(binding, arguments: ["text": .string("\(index)")], timeout: 10, maxCharacters: 1000) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.allSatisfy { $0.status == ToolCallStatus.completed.rawValue })
            #expect(try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }.count == 1)
        }
    }

    @Test func aTimedOutCallerDoesNotLoseTheRotatedToken() async throws {
        try await withServer(["oauth-slow-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let before = try harness.storedToken()
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            // The call gives up while the provider is rotating the refresh token.
            let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 0.2, maxCharacters: 1000)
            #expect(result.status == ToolCallStatus.timedOut.rawValue)
            let rotated = await eventually(timeout: 5) { (try? harness.storedToken().refreshToken) != before.refreshToken }
            #expect(rotated)
            #expect(try await harness.call("echo", ["text": .string("later")]).text == "later")
        }
    }

    @Test func refreshNeverRunsForTeardown() async throws {
        try await withServer(["oauth-short-lived", "session"]) { harness in
            try await harness.signIn(SignInScript())
            let refreshes = try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }.count
            await harness.manager.stop(serverID: harness.config.id)
            let after = try await harness.contacts()
            #expect(after.filter { $0.body["grant_type"] as? String == "refresh_token" }.count == refreshes)
        }
    }

    @Test func noRefreshStartsOnceQuitHasBegun() async throws {
        let harness = try await MCPHTTPHarness(behaviors: ["oauth"])
        defer { harness.finish() }
        try await harness.signIn(SignInScript())
        let list = await harness.catalog()
        let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
        try await harness.expireTokens()
        harness.manager.shutdownSync(grace: 0.1)
        _ = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 2, maxCharacters: 1000)
        #expect(try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }.isEmpty)
    }

    @Test func aRefusedKeychainWriteKeepsTheTokenForThisRunAndSaysSo() async throws {
        try await withServer { harness in
            try await harness.signIn(SignInScript())
            _ = await harness.catalog()
            harness.oauthStore.failWrites(true)
            defer { harness.oauthStore.failWrites(false) }
            var updates = harness.manager.updates.makeAsyncIterator()
            try await harness.expireTokens()
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
            var sawNotice = false
            let deadline = Date().addingTimeInterval(3)
            while !sawNotice, Date() < deadline {
                let next = await updates.next()
                sawNotice = next?.signInNeed == .notSaved
            }
            #expect(sawNotice)
        }
    }

    // MARK: Ending a sign-in

    @Test func signOutClosesTheConnectionAndContactsNoProvider() async throws {
        try await withServer(["session"]) { harness in
            try await harness.signIn(SignInScript())
            _ = await harness.catalog()
            let token = try harness.storedToken().accessToken
            try await harness.manager.signOut(serverID: harness.config.id)
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
            #expect(await harness.manager.signInInfo(serverID: harness.config.id) == nil)
            let contacts = try await harness.contacts()
            let last = try #require(contacts.last)
            #expect(last.http == "DELETE")
            #expect(last.headers["authorization"] == "Bearer \(token)")
            #expect(contacts.filter { $0.path == "/token" }.count == 1)

            // And nothing is sent with the old token afterwards.
            let state = await harness.manager.connect(harness.config)
            #expect(state.signInNeed == .signIn)
            let final = try await harness.contacts()
            #expect(final.dropFirst(contacts.count).allSatisfy { $0.headers["authorization"] == nil })
        }
    }

    @Test func signOutDuringARefreshDoesNotBringTheTokenBack() async throws {
        try await withServer(["oauth-slow-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            let running = Task { await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            try await harness.manager.signOut(serverID: harness.config.id)
            _ = await running.value
            try await Task.sleep(nanoseconds: 1_200_000_000)
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
        }
    }

    @Test func deletingTheServerDuringARefreshLeavesNothing() async throws {
        try await withServer(["oauth-slow-refresh"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireTokens()
            let running = Task { await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            await harness.manager.forget(serverID: harness.config.id)
            _ = await running.value
            try await Task.sleep(nanoseconds: 1_200_000_000)
            #expect(try harness.oauthStore.tokens(for: harness.config.id) == nil)
            #expect(try harness.oauthStore.clients(for: harness.config.id).isEmpty)
        }
    }

    @Test func deletingAServerNoConnectionWasOpenedForStillRemovesItsSignIn() async throws {
        let oauth = InMemoryMCPOAuthStore()
        let manager = MCPConnectionManager(secrets: InMemoryMCPSecretStore(), oauthStore: oauth, pathResolver: mcpTestResolver(), clientVersion: "t")
        let id = UUID()
        let tokens = MCPOAuthTokens(accessToken: "fake", refreshToken: nil, expiresAt: nil, issuer: "i", resource: "r", tokenEndpoint: "t",
                                    scopes: [], clientID: "c", clientSecret: nil, authMethod: "none")
        try oauth.setTokens(tokens, for: id)
        await manager.forget(serverID: id)
        #expect(try oauth.tokens(for: id) == nil)
    }

    @Test func deletingTheServerDuringASignInVoidsIt() async throws {
        try await withServer { harness in
            let manager = harness.manager
            let id = harness.config.id
            let script = SignInScript()
            script.answer = { _ in .proceed(host: nil) }
            let browser: MCPOAuthOpen = { _ in
                Task.detached { await manager.forget(serverID: id) }
                return true
            }
            await #expect(throws: MCPError.oauth(.cancelled)) {
                try await manager.signIn(harness.config, approve: script.approve, open: browser, willSignIn: {})
            }
            try #expect(try harness.oauthStore.tokens(for: id) == nil)
        }
    }

    @Test func aTokenForAnotherAddressIsNeverSent() async throws {
        try await withServer { harness in
            try await harness.signIn(SignInScript())
            var stale = try harness.storedToken()
            await harness.manager.stop(serverID: harness.config.id)
            stale.resource = "http://127.0.0.1:1/elsewhere"
            try harness.oauthStore.setTokens(stale, for: harness.config.id)
            let seen = try await harness.contacts().count
            _ = await harness.manager.connect(harness.config)
            let after = try await harness.contacts().dropFirst(seen)
            try #require(!after.isEmpty)
            #expect(after.allSatisfy { $0.headers["authorization"] == nil })
        }
    }

    // MARK: Step-up

    @Test func moreAccessAsksForTheUnionAndNeverOpensAnythingByItself() async throws {
        try await withServer(["oauth-step-up"]) { harness in
            let script = SignInScript()
            try await harness.signIn(script)
            let list = await harness.catalog()
            let add = try #require(list.bindings.first { $0.tool.name == "add" })
            let refused = await harness.manager.call(add, arguments: ["a": .int(1), "b": .int(2)], timeout: 5, maxCharacters: 1000)
            #expect(refused.status == ToolCallStatus.notCalled.rawValue)
            #expect(refused.text.contains("more permission"))
            #expect(script.opened.count == 1)
            // The other tools still work: the connection stays.
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")

            let again = SignInScript()
            try await harness.signIn(again)
            let review = try #require(again.reviews.first)
            #expect(review.newScopes == ["files:write"])
            #expect(review.scopes.contains("files:read"))
            let page = try #require(again.opened.first)
            #expect(query(page, "scope")?.split(separator: " ").contains("files:read") == true)
            #expect(query(page, "scope")?.split(separator: " ").contains("files:write") == true)
            let list2 = await harness.catalog()
            let add2 = try #require(list2.bindings.first { $0.tool.name == "add" })
            let done = await harness.manager.call(add2, arguments: ["a": .int(1), "b": .int(2)], timeout: 5, maxCharacters: 1000)
            #expect(done.status == ToolCallStatus.completed.rawValue)
        }
    }

    // MARK: Clients

    @Test func aRegistrationIsReusedOnTheSamePort() async throws {
        try await withServer { harness in
            let first = SignInScript()
            try await harness.signIn(first)
            try await harness.manager.signOut(serverID: harness.config.id)
            let second = SignInScript()
            try await harness.signIn(second)
            #expect(try await harness.contacts().filter { $0.path == "/register" }.count == 1)
            let one = try #require(first.opened.first)
            let two = try #require(second.opened.first)
            #expect(query(one, "redirect_uri") == query(two, "redirect_uri"))
            #expect(query(one, "client_id") == query(two, "client_id"))
        }
    }

    @Test func aTakenPortMeansARegistrationNotAMismatch() async throws {
        try await withServer { harness in
            let first = SignInScript()
            try await harness.signIn(first)
            try await harness.manager.signOut(serverID: harness.config.id)
            let redirect = try #require(first.opened.first.flatMap { query($0, "redirect_uri") })
            let port = try #require(URL(string: redirect)?.port)
            let holder = try MCPOAuthLoopback(port: port)
            defer { holder.close() }
            let second = SignInScript()
            try await harness.signIn(second)
            #expect(try await harness.contacts().filter { $0.path == "/register" }.count == 2)
            #expect(second.opened.first.flatMap { query($0, "redirect_uri") } != redirect)
        }
    }

    @Test func registrationIsNativeAndPublic() async throws {
        try await withServer { harness in
            try await harness.signIn(SignInScript())
            let body = try #require(try await harness.contacts().first { $0.path == "/register" }?.body)
            #expect(body["client_name"] as? String == "Parley")
            #expect(body["application_type"] as? String == "native")
            #expect(body["token_endpoint_auth_method"] as? String == "none")
            #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
            #expect(body["response_types"] as? [String] == ["code"])
            #expect((body["redirect_uris"] as? [String])?.count == 1)
            #expect(body.count == 6)
        }
    }

    @Test func aReturnedSecretIsKeptAndUsed() async throws {
        try await withServer(["oauth-confidential"]) { harness in
            try await harness.signIn(SignInScript())
            let stored = try harness.storedToken()
            #expect(stored.clientSecret?.hasPrefix("fake-client-secret") == true)
            #expect(stored.authMethod == "client_secret_basic")
            try await harness.expireTokens()
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
        }
    }

    private func setClient(_ harness: MCPHTTPHarness, id: String, secret: String = "", port: Int? = nil) throws {
        var secrets = try harness.store.secrets(for: harness.config.id)
        secrets.oauthClientID = id
        secrets.oauthClientSecret = secret
        secrets.oauthCallbackPort = port
        try harness.store.setSecrets(secrets, for: harness.config.id)
    }

    @Test func aClientIDIsUsedWithoutRegistering() async throws {
        try await withServer { harness in
            try setClient(harness, id: "fake-own-client")
            let script = SignInScript()
            try await harness.signIn(script)
            #expect(script.opened.first.flatMap { query($0, "client_id") } == "fake-own-client")
            #expect(!(try await harness.paths().contains("POST /register")))
        }
    }

    @Test func aFixedPortIsTheRedirectURI() async throws {
        try await withServer(["oauth-no-registration"]) { harness in
            let port = try mcpFreePort()
            try setClient(harness, id: "fake-own-client", port: port)
            let script = SignInScript()
            try await harness.signIn(script)
            #expect(script.opened.first.flatMap { query($0, "redirect_uri") } == "http://127.0.0.1:\(port)/callback")
        }
    }

    @Test func noRegistrationAndNoClientIDSaysWhatToDoBeforeTheBrowser() async throws {
        try await withServer(["oauth-no-registration"]) { harness in
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.clientIDRequired))
            #expect(script.opened.isEmpty)
        }
    }

    @Test func aMetadataURLNeedsAProviderThatTakesOne() async throws {
        try await withServer { harness in
            try setClient(harness, id: "https://fake.example/client.json")
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.clientMetadataUnsupported))
            #expect(script.opened.isEmpty)
        }
    }

    @Test func aClientIDIsNeverSentToADifferentProvider() async throws {
        try await withServer { harness in
            try setClient(harness, id: "fake-own-client")
            try harness.oauthStore.setClients(["https://earlier.example": MCPOAuthClient(
                clientID: "fake-own-client", clientSecret: nil, authMethod: "none", redirectURI: nil, isUserEntered: true)], for: harness.config.id)
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.clientIssuerChanged))
            #expect(script.opened.isEmpty)
        }
    }

    // MARK: What the review found

    @Test func aProviderThatAnswersBeforeOpenReturns() async throws {
        try await withServer { harness in
            let script = SignInScript()
            script.answersBeforeOpenReturns = true
            try await harness.signIn(script)
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
        }
    }

    @Test func approvalsEndBeforeTheNewTokenExists() async throws {
        try await withServer { harness in
            let store = harness.oauthStore
            let id = harness.config.id
            let script = SignInScript()
            let saw = MCPFlag()
            try await harness.manager.signIn(harness.config, approve: script.approve, open: script.open, willSignIn: {
                if case .some(.none) = try? store.tokens(for: id) { saw.set() }
            })
            #expect(saw.isSet)
            _ = try harness.storedToken()
        }
    }

    @Test func noScopeKnownMeansNoScopeSent() async throws {
        try await withServer(["oauth-no-scope"]) { harness in
            let script = SignInScript()
            try await harness.signIn(script)
            let page = try #require(script.opened.first)
            #expect(query(page, "scope") == nil)
        }
    }

    @Test func aBearer403NeedsASignInLikeA401() async throws {
        try await withServer(["oauth-bearer-403"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let add = try #require(list.bindings.first { $0.tool.name == "add" })
            let refused = await harness.manager.call(add, arguments: ["a": .int(1), "b": .int(2)], timeout: 5, maxCharacters: 1000)
            #expect(refused.status == ToolCallStatus.notCalled.rawValue)
            #expect(refused.text.contains("sign in"))
        }
    }

    @Test func aReconnectToAModernServerStopsAtTheFirstRefusal() async throws {
        try await withServer(era: "modern") { harness in
            try await harness.signIn(SignInScript())
            try await harness.manager.signOut(serverID: harness.config.id)
            let before = try await harness.contacts().count
            _ = await harness.manager.connect(harness.config)
            let after = try await harness.contacts().count
            #expect(after == before + 1)
        }
    }

    @Test func tokensSurviveAReconnectWhileTheKeychainRefusesThem() async throws {
        try await withServer { harness in
            try await harness.signIn(SignInScript())
            _ = await harness.catalog()
            let saved = try harness.storedToken()
            harness.oauthStore.failWrites(true)
            try await harness.expireTokens()
            #expect(try await harness.call("echo", ["text": .string("x")]).text == "x")
            #expect(try harness.storedToken() == saved)
            // The Keychain now holds a spent refresh token, which a restart must not bring back.
            await harness.manager.stop(serverID: harness.config.id)
            #expect(await harness.manager.connect(harness.config).state == .ready)
            try await harness.expireTokens()
            #expect(try await harness.call("echo", ["text": .string("y")]).text == "y")
            harness.oauthStore.failWrites(false)
            await harness.manager.stop(serverID: harness.config.id)
            #expect(await harness.manager.connect(harness.config).state == .ready)
            #expect(try harness.storedToken().accessToken != saved.accessToken)
            let refreshes = try await harness.contacts().filter { $0.body["grant_type"] as? String == "refresh_token" }.count
            #expect(refreshes == 2)
        }
    }

    @Test func aStepUpAfterARelaunchKeepsWhatWasGranted() async throws {
        try await withServer(["oauth-step-up"]) { harness in
            try await harness.signIn(SignInScript())
            var stored = try harness.storedToken()
            stored.scopes.append("files:admin")
            try harness.oauthStore.setTokens(stored, for: harness.config.id)
            let relaunched = MCPConnectionManager(secrets: harness.store, oauthStore: harness.oauthStore, pathResolver: mcpTestResolver(),
                                                  clientVersion: "test", stopGrace: 0.3)
            defer { relaunched.shutdownSync(grace: 0.2) }
            let script = SignInScript()
            try await relaunched.signIn(harness.config, approve: script.approve, open: script.open, willSignIn: {})
            let scopes = try #require(script.opened.first.flatMap { query($0, "scope") })
            #expect(scopes.split(separator: " ").contains("files:admin"))
        }
    }

    @Test func aRegistrationOutlivesAnAbandonedSignIn() async throws {
        try await withServer(["oauth-denied"]) { harness in
            #expect(await harness.failure(signingInWith: SignInScript()) == .oauth(.denied("access_denied")))
            #expect(await harness.failure(signingInWith: SignInScript()) == .oauth(.denied("access_denied")))
            let registrations = try await harness.contacts().filter { $0.path == "/register" }.count
            #expect(registrations == 1)
        }
    }

    @Test func aTypedInClientStaysBoundThroughInvalidClient() async throws {
        try await withServer(["oauth-invalid-client"]) { harness in
            try setClient(harness, id: "fake-own-client")
            try await harness.signIn(SignInScript())
            _ = await harness.catalog()
            try await harness.expireTokens()
            _ = await harness.catalog()
            let tokens = try harness.oauthStore.tokens(for: harness.config.id)
            #expect(tokens == nil)
            let clients = try harness.oauthStore.clients(for: harness.config.id)
            #expect(clients.values.first?.clientID == "fake-own-client")
        }
    }

    @Test func anOldSecretBesideANewClientIDIsNotSent() async throws {
        try await withServer { harness in
            try setClient(harness, id: "fake-new-client", secret: "fake-old-secret")
            try harness.oauthStore.setClients(["https://earlier.example": MCPOAuthClient(
                clientID: "fake-old-client", clientSecret: "fake-old-secret", authMethod: "client_secret_post", redirectURI: nil, isUserEntered: true)], for: harness.config.id)
            let script = SignInScript()
            #expect(await harness.failure(signingInWith: script) == .oauth(.clientIssuerChanged))
            #expect(script.opened.isEmpty)
        }
    }

    @Test func aCancelledFlowAsksNothing() async throws {
        try await withServer { harness in
            let manager = harness.manager
            let config = harness.config
            let asked = MCPFlag()
            let flow = Task {
                try await manager.signIn(config, approve: { _ in
                    asked.set()
                    return .proceed(host: nil)
                }, open: { _ in true }, willSignIn: {})
            }
            flow.cancel()
            await #expect(throws: MCPError.oauth(.cancelled)) { try await flow.value }
            #expect(!asked.isSet)
        }
    }

    // MARK: Leaks

    @Test func tokensNeverReachAnythingThatIsSavedOrShown() async throws {
        try await withServer(["oauth-echo"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let echo = try #require(list.bindings.first { $0.tool.name == "echo" })
            let add = try #require(list.bindings.first { $0.tool.name == "add" })
            let tokens = try harness.storedToken()
            let secrets = [tokens.accessToken, try #require(tokens.refreshToken)]

            let echoed = await harness.manager.call(echo, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 2000)
            let failed = await harness.manager.call(add, arguments: ["a": .int(1), "b": .int(2)], timeout: 5, maxCharacters: 2000)
            #expect(echoed.text.contains(MCPTokenScrubber.replacement))
            // Written with `\/` in this body, so a plain search would miss it.
            #expect(failed.text.contains(MCPTokenScrubber.replacement))

            var texts = [echoed.text, failed.text]
            texts += await harness.manager.logs(serverID: harness.config.id)
            let config = try JSONEncoder().encode(harness.config)
            texts.append(String(decoding: config, as: UTF8.self))
            let stored = try JSONEncoder().encode(try harness.store.secrets(for: harness.config.id))
            texts.append(String(decoding: stored, as: UTF8.self))
            let snapshot = await harness.manager.connect(harness.config)
            texts.append("\(snapshot)")
            for failure in [MCPError.needsAuthorization(status: 401), .insufficientScope, .oauth(.tokenRefused("x"))] {
                texts.append(failure.summary)
            }
            for secret in secrets {
                #expect(!texts.contains { $0.contains(secret) })
            }
        }
    }

    @Test func aTokenCutByALongErrorLeavesNoPieceBehind() async throws {
        try await withServer(["oauth-echo", "oauth-long-error"]) { harness in
            try await harness.signIn(SignInScript())
            let list = await harness.catalog()
            let add = try #require(list.bindings.first { $0.tool.name == "add" })
            let token = try harness.storedToken().accessToken
            let failed = await harness.manager.call(add, arguments: ["a": .int(1), "b": .int(2)], timeout: 5, maxCharacters: 4000)
            #expect(!failed.text.contains(String(token.prefix(8))))
        }
    }

    @Test func aTokenStaysOutOfEveryURL() async throws {
        try await withServer { harness in
            let script = SignInScript()
            try await harness.signIn(script)
            _ = try await harness.call("echo", ["text": .string("x")])
            let tokens = try harness.storedToken()
            let paths = try await harness.contacts().map(\.path) + script.opened.map(\.absoluteString)
            #expect(!paths.contains { $0.contains(tokens.accessToken) })
            let refreshToken = try #require(tokens.refreshToken)
            #expect(!paths.contains { $0.contains(refreshToken) })
        }
    }
}
