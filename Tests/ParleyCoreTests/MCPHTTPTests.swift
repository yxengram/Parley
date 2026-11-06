import Foundation
import Testing
@testable import ParleyCore

// The client and manager against tools/mock_mcp_server.py over Streamable HTTP on 127.0.0.1.

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPHTTPTests {
    private func withServer(era: String = "legacy", behaviors: [String] = [], headers: [String: String] = [:], version: String? = nil,
                            environment: [String: String] = [:], _ body: (MCPHTTPHarness) async throws -> Void) async throws {
        let harness = try await MCPHTTPHarness(era: era, behaviors: behaviors, headers: headers, version: version, environment: environment)
        defer { harness.finish() }
        try await body(harness)
    }

    private func failure(_ harness: MCPHTTPHarness) async -> String? {
        let state = await harness.manager.connect(harness.config).state
        if case .failed(let message) = state { return message }
        return nil
    }

    @Test func legacyJSON() async throws {
        try await withServer { harness in
            let state = await harness.manager.connect(harness.config)
            #expect(state.state == .ready)
            #expect(state.protocolVersion == MCPProtocol.legacyVersion)
            #expect(try await harness.call("echo", ["text": .string("over http")]).text == "over http")

            let requests = try await harness.requests()
            try #require(requests.count > 1)
            #expect(requests.first?.method == "initialize")
            #expect(requests.allSatisfy { $0.headers["accept"]?.contains("application/json") == true && $0.headers["accept"]?.contains("text/event-stream") == true })
            let later = try #require(requests.first { $0.method == "tools/list" })
            #expect(later.headers["mcp-protocol-version"] == MCPProtocol.legacyVersion)
            #expect(requests[0].headers["mcp-protocol-version"] == nil)
            #expect(later.headers["mcp-method"] == nil)
            #expect(requests.contains { $0.method == "notifications/initialized" })
        }
    }

    @Test func eventStreamsWithCommentsAndNotifications() async throws {
        try await withServer(behaviors: ["sse"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("streamed")])
            #expect(echo.text == "streamed")
            let big = try await harness.call("big", ["chars": .int(200_000)])
            #expect(big.originalCharacters == 200_000)
        }
    }

    @Test func modernEventStreams() async throws {
        try await withServer(era: "modern", behaviors: ["sse"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("streamed")])
            #expect(echo.text == "streamed")
        }
    }

    @Test func sessionIsEchoedAndDeletedOnStop() async throws {
        try await withServer(behaviors: ["session"]) { harness in
            _ = try await harness.call("echo", ["text": .string("x")])
            await harness.manager.stop(serverID: harness.config.id)
            let requests = try await harness.requests()
            try #require(requests.count > 1)
            #expect(requests[0].headers["mcp-session-id"] == nil)
            let session = try #require(requests.first { $0.method == "tools/list" }?.headers["mcp-session-id"])
            #expect(requests.dropFirst().allSatisfy { $0.headers["mcp-session-id"] == session })
            #expect(requests.last?.http == "DELETE")
            #expect(requests.last?.headers["mcp-session-id"] == session)
        }
    }

    @Test func aRefusedDeleteIsFine() async throws {
        try await withServer(behaviors: ["session", "no-delete"]) { harness in
            _ = await harness.catalog()
            await harness.manager.stop(serverID: harness.config.id)
            let requests = try await harness.requests()
            #expect(requests.last?.http == "DELETE")
        }
    }

    @Test func noSessionNoDelete() async throws {
        try await withServer { harness in
            _ = await harness.catalog()
            await harness.manager.stop(serverID: harness.config.id)
            let requests = try await harness.requests()
            #expect(requests.allSatisfy { $0.http == "POST" })
        }
    }

    @Test func aLostSessionStartsOverOnce() async throws {
        try await withServer(behaviors: ["session"]) { harness in
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "echo" })
            try await harness.expireSessions()
            let result = await harness.manager.call(binding, arguments: ["text": .string("again")], timeout: 5, maxCharacters: 1000)
            #expect(result.text == "again")
            let requests = try await harness.requests()
            #expect(requests.filter { $0.method == "initialize" }.count == 2)
            #expect(requests.filter { $0.method == "tools/call" }.count == 2)
            let second = try #require(requests.last { $0.method == "initialize" })
            #expect(second.headers["mcp-session-id"] == nil)
        }
    }

    @Test func aLostSessionDuringListing() async throws {
        try await withServer(behaviors: ["session"]) { harness in
            _ = await harness.catalog()
            try await harness.expireSessions()
            let again = await harness.catalog()
            #expect(again.unavailable.isEmpty)
            #expect(!again.bindings.isEmpty)
        }
    }

    @Test func redirectsAreRefusedAndNothingReachesTheTarget() async throws {
        let target = try await MCPHTTPHarness()
        defer { target.finish() }
        try await withServer(behaviors: ["redirect"], environment: ["MOCK_REDIRECT_PORT": String(target.port)]) { harness in
            let message = await failure(harness)
            #expect(message?.contains("Redirect to http://127.0.0.1:\(target.port)/") == true)
            #expect(message?.contains("not followed") == true)
            let reached = try await target.requests()
            #expect(reached.isEmpty)
        }
    }

    @Test func unauthorizedSaysSoAndDiscoversNothing() async throws {
        try await withServer(behaviors: ["401"]) { harness in
            let message = await failure(harness)
            #expect(message == MCPError.needsAuthorization(status: 401).errorDescription)
            let requests = try await harness.requests()
            try #require(requests.count == 1)
            #expect(requests[0].method == "initialize")
        }
    }

    @Test func staticHeadersAreSentAndCannotReplaceProtocolOnes() async throws {
        try await withServer(headers: ["Authorization": "Bearer fake-header-token", "MCP-Protocol-Version": "1999-01-01", "X-Custom": "yes"]) { harness in
            _ = try await harness.call("echo", ["text": .string("x")])
            let requests = try await harness.requests()
            #expect(requests.allSatisfy { $0.headers["authorization"] == "Bearer fake-header-token" })
            #expect(requests.allSatisfy { $0.headers["x-custom"] == "yes" })
            let list = try #require(requests.first { $0.method == "tools/list" })
            #expect(list.headers["mcp-protocol-version"] == MCPProtocol.legacyVersion)
            #expect(requests.allSatisfy { $0.headers["cookie"] == nil })
        }
    }

    @Test func aHeaderWithALineBreakIsRefusedBeforeAnythingIsSent() async throws {
        try await withServer(headers: ["X-Bad": "a\r\nEvil: 1"]) { harness in
            let message = await failure(harness)
            #expect(message?.contains("X-Bad") == true)
            let requests = try await harness.requests()
            #expect(requests.isEmpty)
        }
    }

    @Test func aBadURLIsNamedWithoutRepeatingIt() async throws {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "bad", kind: MCPServerConfig.kindHTTP)
        try store.setSecrets(MCPServerSecrets(url: "ftp://x.test/fake-url-secret"), for: config.id)
        let catalog = await manager.catalog(for: [config])
        #expect(catalog.unavailable.first?.reason == MCPError.invalidURL.errorDescription)
    }

    @Test func anUnknownKindDoesNotBreakTheOthers() async throws {
        let manager = MCPConnectionManager(secrets: InMemoryMCPSecretStore(), pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "future", kind: "carrier-pigeon")
        let catalog = await manager.catalog(for: [config])
        #expect(catalog.unavailable.first?.reason.contains("carrier-pigeon") == true)
    }

    // MARK: Modern

    @Test func modernHeadersOnEveryRequest() async throws {
        try await withServer(era: "modern") { harness in
            let state = await harness.manager.connect(harness.config)
            #expect(state.state == .ready)
            #expect(state.protocolVersion == MCPProtocol.modernVersion)
            _ = try await harness.call("echo", ["text": .string("x")])
            let requests = try await harness.requests()
            #expect(requests.map(\.method).prefix(2) == ["initialize", "server/discover"])
            for request in requests.dropFirst() {
                #expect(request.headers["mcp-protocol-version"] == MCPProtocol.modernVersion)
                #expect(request.headers["mcp-method"] == request.method)
            }
            let call = try #require(requests.first { $0.method == "tools/call" })
            #expect(call.headers["mcp-name"] == "echo")
            #expect(!requests.contains { $0.method == "notifications/initialized" })
        }
    }

    @Test func parametersAreMirroredIntoHeaders() async throws {
        try await withServer(era: "modern") { harness in
            let plain = try await harness.call("header_ok", ["region": .string("eu-west1"), "limit": .int(5), "query": .string("q")])
            #expect(plain.status == ToolCallStatus.completed.rawValue, "\(plain.text)")
            let encoded = try await harness.call("header_ok", ["region": .string("世界 ")])
            #expect(encoded.status == ToolCallStatus.completed.rawValue, "\(encoded.text)")
            let omitted = try await harness.call("header_ok", ["query": .string("q")])
            #expect(omitted.status == ToolCallStatus.completed.rawValue, "\(omitted.text)")

            let calls = try await harness.requests().filter { $0.method == "tools/call" }
            try #require(calls.count == 3)
            #expect(calls[0].headers["mcp-param-region"] == "eu-west1")
            #expect(calls[0].headers["mcp-param-limit"] == "5")
            #expect(calls[0].headers["mcp-param-query"] == nil)
            #expect(calls[1].headers["mcp-param-region"]?.hasPrefix("=?base64?") == true)
            #expect(calls[2].headers["mcp-param-region"] == nil)
        }
    }

    @Test func toolsWithInvalidHeaderMarksAreHidden() async throws {
        try await withServer(era: "modern") { harness in
            let state = await harness.manager.connect(harness.config)
            #expect(state.tools.contains { $0.name == "header_ok" })
            #expect(!state.tools.contains { $0.name == "header_bad" })
            #expect(state.hiddenTools.first { $0.name == "header_bad" }?.reason.contains("x-mcp-header") == true)
        }
    }

    @Test func aHeaderMismatchRelistsAndRetriesOnce() async throws {
        try await withServer(era: "modern", behaviors: ["header-mismatch"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("retried")])
            #expect(echo.text == "retried")
            let requests = try await harness.requests()
            #expect(requests.filter { $0.method == "tools/call" }.count == 2)
            let ids = requests.filter { $0.method == "tools/call" }.compactMap { $0.body["id"] as? Int }
            #expect(ids.count == 2)
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func aBrokenStreamIsNeverReissued() async throws {
        try await withServer(behaviors: ["drop-mid-call"]) { harness in
            let result = try await harness.call("echo", ["text": .string("x")])
            #expect(result.status == ToolCallStatus.failed.rawValue)
            #expect(result.text.contains("may or may not have run"))
            let calls = try await harness.requests().filter { $0.method == "tools/call" }
            #expect(calls.count == 1)
        }
    }

    @Test func aHugeMessageFailsCleanly() async throws {
        try await withServer(behaviors: ["huge-message"]) { harness in
            let result = try await harness.call("echo", ["text": .string("x")])
            #expect(result.status == ToolCallStatus.failed.rawValue)
            #expect(result.text.contains("16 MB"))
        }
    }

    @Test func inputRequiredEchoesStateWithANewID() async throws {
        try await withServer(era: "modern", behaviors: ["input-required-state"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("done")])
            #expect(echo.text == "done")
            let calls = try await harness.requests().filter { $0.method == "tools/call" }
            #expect(calls.count == 3)
            #expect(Set(calls.compactMap { $0.body["id"] as? Int }).count == 3)
            let states = calls.map { ($0.body["params"] as? [String: Any])?["requestState"] as? String }
            #expect(states == [nil, "state-1", "state-2"])
        }
    }

    @Test func inputRequestsFail() async throws {
        try await withServer(era: "modern", behaviors: ["input-required-requests"]) { harness in
            let result = try await harness.call("echo", ["text": .string("x")])
            #expect(result.status == ToolCallStatus.failed.rawValue)
            #expect(result.text.contains("input Parley does not support"))
        }
    }

    @Test func anUnknownResultTypeIsInvalid() async throws {
        try await withServer(era: "modern", behaviors: ["unknown-result-type"]) { harness in
            let message = await failure(harness)
            #expect(message?.contains("resultType") == true)
        }
    }

    @Test func freshnessFollowsTtl() async throws {
        try await withServer(era: "modern", behaviors: ["long-ttl"]) { harness in
            _ = await harness.catalog()
            _ = await harness.catalog()
            let lists = try await harness.requests().filter { $0.method == "tools/list" }
            #expect(lists.count == 1)
        }
        try await withServer(era: "modern") { harness in
            _ = await harness.catalog()
            _ = await harness.catalog()
            let lists = try await harness.requests().filter { $0.method == "tools/list" }
            #expect(lists.count == 2)
        }
    }

    @Test func aModernVerdictIsRememberedForARestart() async throws {
        try await withServer(era: "modern") { harness in
            _ = await harness.manager.connect(harness.config)
            await harness.manager.stop(serverID: harness.config.id)
            _ = await harness.catalog()
            let handshakes = try await harness.requests().filter { $0.method == "initialize" }
            #expect(handshakes.count == 1)
        }
    }

    // MARK: Cancellation

    @Test func legacyCancelSendsANotification() async throws {
        try await withServer { harness in
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "slow" })
            let manager = harness.manager
            let task = Task { await manager.call(binding, arguments: ["seconds": .int(20)], timeout: 30, maxCharacters: 100) }
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            let result = await task.value
            #expect(result.status == ToolCallStatus.cancelled.rawValue)
            let notified = await eventuallyAsync { (try? await harness.requests().contains { $0.method == "notifications/cancelled" }) == true }
            #expect(notified)
            let events = try await harness.log()
            let done = await eventuallyAsync { (try? await harness.log().contains { $0["event"] as? String == "cancelled" }) == true }
            #expect(done, "\(events.count)")
        }
    }

    @Test func modernCancelClosesTheStream() async throws {
        try await withServer(era: "modern") { harness in
            let list = await harness.catalog()
            let binding = try #require(list.bindings.first { $0.tool.name == "slow" })
            let manager = harness.manager
            let task = Task { await manager.call(binding, arguments: ["seconds": .int(20)], timeout: 30, maxCharacters: 100) }
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            _ = await task.value
            let closed = await eventuallyAsync { (try? await harness.log().contains { $0["event"] as? String == "stream-closed" }) == true }
            #expect(closed)
            let requests = try await harness.requests()
            #expect(!requests.contains { $0.method == "notifications/cancelled" })
        }
    }

    @Test func serverRequestsOnAStreamGetAPost() async throws {
        try await withServer(behaviors: ["server-ping", "server-sampling"]) { harness in
            _ = try await harness.call("echo", ["text": .string("x")])
            let answered = await eventuallyAsync {
                ((try? await harness.requests()) ?? []).filter { $0.method == nil && $0.http == "POST" }.count == 2
            }
            #expect(answered)
            let answers = try await harness.requests().filter { $0.method == nil && $0.http == "POST" }
            let sampling = try #require(answers.first { $0.body["id"] as? String == "srv-sampling" })
            #expect((sampling.body["error"] as? [String: Any])?["code"] as? Int == -32601)
            #expect(answers.first { $0.body["id"] as? String == "srv-ping" }?.body["result"] != nil)
        }
    }

    @Test func aDeadServerIsNotEraEvidence() async throws {
        let port = try mcpFreePort()
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "dead", kind: MCPServerConfig.kindHTTP, startupTimeout: 3)
        try store.setSecrets(MCPServerSecrets(url: "http://127.0.0.1:\(port)/mcp"), for: config.id)
        let state = await manager.connect(config)
        guard case .failed = state.state else {
            Issue.record("expected failure, got \(state.state)")
            return
        }
    }

    private func eventuallyAsync(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }
}
