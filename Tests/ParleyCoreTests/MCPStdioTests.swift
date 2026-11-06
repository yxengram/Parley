import Darwin
import Foundation
import Testing
@testable import ParleyCore

// The client and manager against tools/mock_mcp_server.py over stdio.

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPStdioTests {
    private func withServer(era: String = "legacy", behaviors: [String] = [], version: String? = nil,
                            env: [String: String] = [:], startupTimeout: Double = 15,
                            _ body: (MCPStdioHarness) async throws -> Void) async throws {
        let harness = try MCPStdioHarness(era: era, behaviors: behaviors, version: version, startupTimeout: startupTimeout, env: env)
        defer { harness.finish() }
        try await body(harness)
    }

    private func snapshot(_ harness: MCPStdioHarness) async -> MCPServerSnapshot {
        await harness.manager.connect(harness.config)
    }

    // MARK: Handshake

    @Test func handshakeOnEveryLegacyVersion() async throws {
        for version in MCPProtocol.legacyVersions {
            try await withServer(version: version) { harness in
                let state = await snapshot(harness)
                #expect(state.state == .ready, "\(version)")
                #expect(state.protocolVersion == version)
                #expect(state.serverInfo == "mock-mcp 1.0")
                #expect(state.isRunning)
                #expect(!state.tools.isEmpty)
                #expect(await eventually { mcpMethods(harness.logPath).contains("notifications/initialized") })
                #expect(mcpMethods(harness.logPath).first == "initialize")
                let initialize = try #require(mcpReceived(harness.logPath).first)
                let params = try #require(initialize["params"] as? [String: Any])
                #expect(params["protocolVersion"] as? String == MCPProtocol.legacyVersion)
                #expect((params["capabilities"] as? [String: Any])?.isEmpty == true)
                #expect((params["clientInfo"] as? [String: Any])?["name"] as? String == "Parley")
            }
        }
    }

    @Test func anUnknownVersionIsRefused() async throws {
        try await withServer(version: "1999-01-01") { harness in
            let state = await snapshot(harness)
            guard case .failed(let message) = state.state else {
                Issue.record("expected failure, got \(state.state)")
                return
            }
            #expect(message.contains("1999-01-01"))
            #expect(!mcpMethods(harness.logPath).contains("server/discover"))
        }
    }

    @Test func modernAfterInitializeIsRejected() async throws {
        try await withServer(era: "modern") { harness in
            let state = await snapshot(harness)
            #expect(state.state == .ready)
            #expect(state.protocolVersion == MCPProtocol.modernVersion)
            #expect(state.serverInfo == "mock-mcp 1.0")
            #expect(mcpMethods(harness.logPath).prefix(2) == ["initialize", "server/discover"])
            let discover = try #require(mcpReceived(harness.logPath).first { $0["method"] as? String == "server/discover" })
            let meta = try #require((discover["params"] as? [String: Any])?["_meta"] as? [String: Any])
            #expect(meta[MCPProtocol.metaVersion] as? String == MCPProtocol.modernVersion)
            #expect((meta[MCPProtocol.metaCapabilities] as? [String: Any])?.isEmpty == true)
            #expect((meta[MCPProtocol.metaClientInfo] as? [String: Any])?["name"] as? String == "Parley")

            let result = try await harness.call("echo", ["text": .string("modern")])
            #expect(result.text == "modern")
            let call = try #require(mcpReceived(harness.logPath).first { $0["method"] as? String == "tools/call" })
            #expect(((call["params"] as? [String: Any])?["_meta"] as? [String: Any])?[MCPProtocol.metaVersion] != nil)
        }
    }

    @Test func aDualEraServerIsServedAsLegacy() async throws {
        try await withServer(era: "dual") { harness in
            let state = await snapshot(harness)
            #expect(state.protocolVersion == MCPProtocol.legacyVersion)
            #expect(!mcpMethods(harness.logPath).contains("server/discover"))
        }
    }

    @Test func serversThatDislikeDiscoverConnectWithoutDelay() async throws {
        for behavior in ["silent-on-discover", "exit-on-discover"] {
            try await withServer(behaviors: [behavior]) { harness in
                let started = Date()
                let state = await snapshot(harness)
                #expect(state.state == .ready)
                #expect(Date().timeIntervalSince(started) < 5)
                #expect(!mcpMethods(harness.logPath).contains("server/discover"))
            }
        }
    }

    @Test func modernVersionMismatch() async throws {
        try await withServer(era: "modern", behaviors: ["version-32022"]) { harness in
            let state = await snapshot(harness)
            guard case .failed(let message) = state.state else {
                Issue.record("expected failure, got \(state.state)")
                return
            }
            #expect(message.contains("2099-01-01"))
        }
    }

    @Test func modernEvenWhenDiscoverSaysUnsupportedButListsOurs() async throws {
        try await withServer(era: "modern", behaviors: ["version-32022-listed", "reject-initialize"]) { harness in
            let client = MCPClient(transport: try await self.transport(harness), clientVersion: "t", startupTimeout: 10)
            try await client.connect()
            #expect(client.era == .modern)
        }
    }

    private func transport(_ harness: MCPStdioHarness) async throws -> MCPStdioTransport {
        let secrets = try harness.store.secrets(for: harness.config.id)
        let launch = MCPStdioTransport.Launch(executable: mcpPython, arguments: secrets.args,
                                              environment: ShellPATHResolver.childEnvironment(path: "/usr/bin:/bin", server: [:]),
                                              directory: harness.scratch.url.path)
        let transport = MCPStdioTransport(launch: launch, log: MCPLogBuffer(), registry: nil)
        try await transport.start()
        return transport
    }

    @Test func aSilentServerTimesOutAtStartup() async throws {
        let scratch = try MCPScratch()
        let script = scratch.path("silent.py")
        try "import sys, time\nsys.stderr.write('booting\\n'); sys.stderr.flush()\ntime.sleep(20)\n".write(toFile: script, atomically: true, encoding: .utf8)
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "t", stopGrace: 0.2)
        defer { manager.shutdownSync(grace: 0.1) }
        let config = MCPServerConfig(name: "silent", command: mcpPython, startupTimeout: 0.7)
        try store.setSecrets(MCPServerSecrets(args: ["-I", script]), for: config.id)
        let state = await manager.connect(config)
        guard case .failed(let message) = state.state else {
            Issue.record("expected failure, got \(state.state)")
            return
        }
        #expect(message.contains("did not answer"))
        #expect(message.contains("booting"))
    }

    @Test func aMissingCommandSaysSo() async throws {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "t")
        let config = MCPServerConfig(name: "gone", command: "no-such-mcp-server")
        let catalog = await manager.catalog(for: [config])
        #expect(catalog.bindings.isEmpty)
        #expect(catalog.unavailable.first?.name == "gone")
        #expect(catalog.unavailable.first?.reason.contains("no-such-mcp-server") == true)
    }

    // MARK: Listing

    @Test func pagination() async throws {
        for behavior in ["paginate", "paginate-empty-cursor"] {
            try await withServer(behaviors: [behavior]) { harness in
                let state = await snapshot(harness)
                #expect(state.state == .ready, "\(behavior)")
                #expect(state.tools.contains { $0.name == "env" }, "\(behavior)")
                #expect(state.tools.count + state.hiddenTools.count > 10)
                let lists = mcpReceived(harness.logPath).filter { $0["method"] as? String == "tools/list" }
                try #require(lists.count > 10)
                #expect((lists[1]["params"] as? [String: Any])?["cursor"] != nil)
            }
        }
    }

    @Test func listChangedRefreshesOnlyWhenTold() async throws {
        try await withServer(behaviors: ["list-changed"]) { harness in
            let first = await harness.catalog()
            #expect(!first.bindings.contains { $0.tool.name == "added_tool" })
            func lists() -> Int { mcpMethods(harness.logPath).filter { $0 == "tools/list" }.count }
            #expect(lists() == 1)
            _ = await harness.catalog()
            #expect(lists() == 1, "cached until the server says otherwise")
            let binding = try harness.binding("echo", in: first)
            _ = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 100)
            try await Task.sleep(nanoseconds: 100_000_000)
            let after = await harness.catalog()
            #expect(after.bindings.contains { $0.tool.name == "added_tool" })
            #expect(lists() == 2)
        }
    }

    @Test func withoutListChangedEveryReplyLists() async throws {
        try await withServer { harness in
            _ = await harness.catalog()
            _ = await harness.catalog()
            _ = await harness.catalog()
            #expect(mcpMethods(harness.logPath).filter { $0 == "tools/list" }.count == 3)
        }
    }

    @Test func aChangedDefinitionChangesTheFingerprint() async throws {
        try await withServer(behaviors: ["change-definition"]) { harness in
            let first = try harness.binding("echo", in: await harness.catalog())
            _ = await harness.manager.call(first, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 100)
            let second = try harness.binding("echo", in: await harness.catalog())
            #expect(first.tool.fingerprint != second.tool.fingerprint)
            #expect(first.exposedName == second.exposedName)
        }
    }

    @Test func toolsTheClientCannotUseAreHiddenWithAReason() async throws {
        try await withServer { harness in
            let state = await snapshot(harness)
            #expect(state.hiddenTools.map(\.name) == ["needs_task"])
            // stdio may ignore x-mcp-header.
            #expect(state.tools.contains { $0.name == "header_bad" })
            let boolean = try #require(state.tools.first { $0.name == "bool_schema" })
            #expect(boolean.inputSchema["properties"]?["x"] == .object([:]))
            #expect(state.tools.first { $0.name == "no_args" }?.inputSchema == MCPSchema.normalized(nil))
        }
    }

    @Test func disabledToolsAreNotOffered() async throws {
        try await withServer { harness in
            harness.config.disabledTools = ["echo"]
            let catalog = await harness.catalog()
            #expect(!catalog.bindings.contains { $0.tool.name == "echo" })
            #expect(catalog.bindings.contains { $0.tool.name == "add" })
        }
    }

    @Test func everyToolGetsASafeName() async throws {
        try await withServer { harness in
            let catalog = await harness.catalog()
            #expect(catalog.bindings.count > 15)
            let pattern = try NSRegularExpression(pattern: "^[a-z0-9_-]{1,64}$")
            for binding in catalog.bindings {
                let name = binding.exposedName
                #expect(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil, "\(name)")
            }
            #expect(Set(catalog.bindings.map(\.exposedName)).count == catalog.bindings.count)
            #expect(catalog.chatTools.count == catalog.bindings.count)
        }
    }

    // MARK: Calling

    @Test func results() async throws {
        try await withServer { harness in
            let echo = try await harness.call("echo", ["text": .string("héllo")])
            #expect(echo.text == "héllo")
            #expect(echo.status == ToolCallStatus.completed.rawValue)
            #expect(echo.duration != nil)

            let added = try await harness.call("add", ["a": .int(2), "b": .double(1.5)])
            #expect(added.text == "3.5")

            let none = try await harness.call("no_args")
            #expect(none.text == "no_args ran with {}")

            let fail = try await harness.call("fail")
            #expect(fail.status == ToolCallStatus.toolError.rawValue)
            #expect(fail.text == "The tool reported an error:\nIt broke.")

            let rpc = try await harness.call("rpc_error")
            #expect(rpc.status == ToolCallStatus.failed.rawValue)
            #expect(rpc.text.hasPrefix("The tool call failed:"))
            #expect(rpc.text.contains("Unknown tool arguments"))

            let image = try await harness.call("image")
            #expect(image.text.hasPrefix("Here is a picture."))
            #expect(image.omitted == ["image/png, 2 KB"])

            let mixed = try await harness.call("mixed")
            #expect(mixed.text.contains("text part"))
            #expect(mixed.text.contains("[Link: report file:///tmp/report.txt]"))
            #expect(mixed.text.contains("embedded text"))
            #expect(mixed.text.contains("[Unsupported content: hologram]"))
            #expect(mixed.omitted?.count == 3)

            #expect(try await harness.call("structured_only").text == #"{"a":[true,null],"b":1}"#)
        }
    }

    @Test func hugeResultsAreCapped() async throws {
        try await withServer { harness in
            let big = try await harness.call("big", ["chars": .int(1_000_000)], maxCharacters: 1000)
            #expect(big.originalCharacters == 1_000_000)
            #expect(big.text.count < 1100)
            #expect(big.text.hasSuffix("[Truncated by Parley: showing the first 1000 of 1000000 characters.]"))
        }
    }

    @Test func aMessageOverTheLimitEndsTheConnection() async throws {
        try await withServer { harness in
            let catalog = await harness.catalog()
            _ = catalog
            let transport = MCPStdioTransport(
                launch: .init(executable: mcpPython, arguments: try harness.store.secrets(for: harness.config.id).args,
                              environment: ShellPATHResolver.childEnvironment(path: "/usr/bin:/bin", server: [:]),
                              directory: harness.scratch.url.path),
                log: MCPLogBuffer(), registry: nil, maxMessageBytes: 64 * 1024)
            let client = MCPClient(transport: transport, clientVersion: "t", startupTimeout: 10)
            try await transport.start()
            try await client.connect()
            let list = try await client.listTools()
            let big = try #require(list.tools.first { $0.name == "big" })
            await #expect(throws: MCPError.messageTooLarge) {
                _ = try await client.callTool(big, arguments: ["chars": .int(200_000)], timeout: 10)
            }
            await transport.close(grace: 0.2)
        }
    }

    @Test func serverToClientRequests() async throws {
        try await withServer(behaviors: ["server-ping", "server-sampling", "server-roots"]) { harness in
            _ = await snapshot(harness)
            let answered = await eventually {
                mcpReceived(harness.logPath).filter { ($0["id"] as? String)?.hasPrefix("srv-") == true }.count == 3
            }
            #expect(answered)
            let answers = mcpReceived(harness.logPath).filter { ($0["id"] as? String)?.hasPrefix("srv-") == true }
            let ping = try #require(answers.first { $0["id"] as? String == "srv-ping" })
            #expect((ping["result"] as? [String: Any])?.isEmpty == true)
            for id in ["srv-sampling", "srv-roots"] {
                let answer = try #require(answers.first { $0["id"] as? String == id })
                #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32601)
            }
        }
    }

    @Test func batches() async throws {
        try await withServer(behaviors: ["batch"], version: "2025-03-26") { harness in
            let state = await snapshot(harness)
            #expect(state.state == .ready)
            #expect(!state.tools.isEmpty)
        }
    }

    @Test func aNoisyStdoutIsIgnored() async throws {
        try await withServer(behaviors: ["noisy-stdout"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("through the noise")])
            #expect(echo.text == "through the noise")
            let logs = await harness.manager.logs(serverID: harness.config.id)
            #expect(logs.contains { $0.hasPrefix("[stdout, ignored] ") })
        }
    }

    @Test func aFloodOfStderrDoesNotBlock() async throws {
        try await withServer(behaviors: ["stderr-flood"]) { harness in
            let echo = try await harness.call("echo", ["text": .string("still here")])
            #expect(echo.text == "still here")
            let logs = await harness.manager.logs(serverID: harness.config.id)
            #expect(logs.count <= 2_000)
            #expect(logs.reduce(0) { $0 + $1.utf8.count } <= 256 * 1024)
            await harness.manager.clearLogs(serverIDs: [harness.config.id])
            let cleared = await harness.manager.logs(serverID: harness.config.id)
            #expect(cleared.count < 2_000)
        }
    }

    @Test func cancellingACallTellsTheServer() async throws {
        try await withServer { harness in
            let binding = try harness.binding("slow", in: await harness.catalog())
            let manager = harness.manager
            let task = Task {
                await manager.call(binding, arguments: ["seconds": .int(30)], timeout: 60, maxCharacters: 100)
            }
            #expect(await eventually { mcpMethods(harness.logPath).contains("tools/call") })
            task.cancel()
            let result = await task.value
            #expect(result.status == ToolCallStatus.cancelled.rawValue)
            #expect(result.text == ToolResultText.interrupted)
            #expect(await eventually { mcpLog(harness.logPath).contains { $0["event"] as? String == "cancelled" } })
            let cancel = try #require(mcpReceived(harness.logPath).first { $0["method"] as? String == "notifications/cancelled" })
            let call = try #require(mcpReceived(harness.logPath).first { $0["method"] as? String == "tools/call" })
            #expect((cancel["params"] as? [String: Any])?["requestId"] as? Int == call["id"] as? Int)
            // The server is still usable, and a late answer goes nowhere.
            #expect(try await harness.call("echo", ["text": .string("after")]).text == "after")
        }
    }

    @Test func aCallTimesOutAndIsCancelled() async throws {
        try await withServer { harness in
            let result = try await harness.call("slow", ["seconds": .int(30)], timeout: 0.3)
            #expect(result.status == ToolCallStatus.timedOut.rawValue)
            #expect(result.text == ToolResultText.timedOut(seconds: 0.3))
            #expect(await eventually { mcpMethods(harness.logPath).contains("notifications/cancelled") })
        }
    }

    // MARK: Crashes

    @Test func aCrashFailsTheCallAndTheNextUseRestarts() async throws {
        try await withServer { harness in
            let first = try await harness.call("crash")
            #expect(first.status == ToolCallStatus.failed.rawValue)
            #expect(first.text == ToolResultText.crashed)
            var restarted: MCPServerSnapshot?
            let again = await harness.catalog()
            #expect(again.unavailable.isEmpty)
            let back = try await harness.call("echo", ["text": .string("back")])
            #expect(back.text == "back")
            restarted = await harness.manager.connect(harness.config)
            #expect(restarted?.state == .ready)
        }
    }

    @Test func crashingOverAndOverStopsRestarts() async throws {
        try await withServer { harness in
            for _ in 0..<3 {
                let result = try await harness.call("crash")
                #expect(result.status == ToolCallStatus.failed.rawValue)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let catalog = await harness.catalog()
            #expect(catalog.bindings.isEmpty)
            #expect(catalog.unavailable.first?.reason.contains("The server stopped 3 times in a minute. Press Connect in Settings > MCP to try again.") == true)
            // The user's button clears it.
            let state = await harness.manager.connect(harness.config)
            #expect(state.state == .ready)
        }
    }

    @Test func writingAfterTheChildDiedDoesNotKillUs() async throws {
        let exited = MCPFlag()
        let process = try MCPStdioProcess(executable: "/bin/sh", args: ["-c", "exit 0"], environment: ["PATH": "/usr/bin:/bin"],
                                          cwd: "/", log: MCPLogBuffer(), onLine: { _ in }, onExit: { _ in exited.set() }, onOversizedLine: {})
        #expect(await eventually { exited.isSet })
        for _ in 0..<50 { process.write(Data(repeating: 0x41, count: 4096)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        process.terminate(grace: 0.1)
    }

    @Test func exitStatusAndTheLastWordsArrive() async throws {
        let lines = MCPLogBuffer()
        let status = MCPStatusBox()
        _ = try MCPStdioProcess(executable: "/bin/sh", args: ["-c", "echo last; exit 3"], environment: ["PATH": "/usr/bin:/bin"], cwd: "/",
                                log: MCPLogBuffer(), onLine: { lines.append(line: String(decoding: $0, as: UTF8.self)) },
                                onExit: { status.set($0) }, onOversizedLine: {})
        #expect(await eventually { status.value != nil })
        #expect(status.value == 3)
        #expect(lines.snapshot() == ["last"])
    }

    // MARK: Lifecycle

    @Test func nothingStartsOrIsReadUntilAskedFor() async throws {
        let harness = try MCPStdioHarness()
        defer { harness.finish() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.store.readCount == 0)
        #expect(harness.pid == nil)
    }

    @Test func aDisabledServerNeverStarts() async throws {
        try await withServer { harness in
            harness.config.isEnabled = false
            let catalog = await harness.catalog()
            #expect(catalog.bindings.isEmpty)
            #expect(catalog.unavailable.isEmpty)
            let state = await harness.manager.connect(harness.config)
            #expect(state.state == .stopped)
            #expect(harness.pid == nil)
            #expect(harness.store.readCount == 0)
        }
    }

    @Test func aChangedConnectionReplacesTheProcess() async throws {
        try await withServer { harness in
            _ = await harness.catalog()
            let first = try #require(harness.pid)
            var edited = harness.config
            edited.connectionFingerprint = "changed"
            let again = await harness.manager.catalog(for: [edited])
            #expect(!again.bindings.isEmpty)
            #expect(await eventually { processIsGone(first) })
            #expect(harness.pid != first)
        }
    }

    @Test func aNameChangeKeepsTheProcess() async throws {
        try await withServer { harness in
            _ = await harness.catalog()
            let first = try #require(harness.pid)
            harness.config.name = "Renamed"
            let again = await harness.catalog()
            #expect(again.bindings.first?.serverName == "Renamed")
            #expect(harness.pid == first)
        }
    }

    @Test func twoConversationsShareOneProcess() async throws {
        try await withServer { harness in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask { _ = await harness.catalog() } }
            }
            #expect(mcpMethods(harness.logPath).filter { $0 == "initialize" }.count == 1)
        }
    }

    @Test func stoppingAWaiterLeavesTheStartRunning() async throws {
        let scratch = try MCPScratch()
        let script = scratch.path("slow-start.py")
        try """
        import runpy, sys, time
        time.sleep(0.5)
        sys.argv = sys.argv[1:]
        runpy.run_path(sys.argv[0], run_name="__main__")
        """.write(toFile: script, atomically: true, encoding: .utf8)
        let harness = try MCPStdioHarness()
        defer { harness.finish() }
        var secrets = try harness.store.secrets(for: harness.config.id)
        secrets.args = ["-I", script] + secrets.args.dropFirst()
        try harness.store.setSecrets(secrets, for: harness.config.id)

        let waiter = Task { await harness.catalog() }
        #expect(await eventually { harness.store.readCount > 0 })
        let cancelledAt = Date()
        waiter.cancel()
        _ = await waiter.value
        #expect(Date().timeIntervalSince(cancelledAt) < 0.3)
        // The first one carried on, so this one finds it (or joins it).
        let catalog = await harness.catalog()
        #expect(!catalog.bindings.isEmpty)
        #expect(mcpMethods(harness.logPath).filter { $0 == "initialize" }.count == 1)
    }

    @Test func updatesReportStatusAndEndAtShutdown() async throws {
        let harness = try MCPStdioHarness()
        let collected = Task { () -> [MCPServerState] in
            var states: [MCPServerState] = []
            for await snapshot in harness.manager.updates { states.append(snapshot.state) }
            return states
        }
        _ = await harness.catalog()
        await harness.manager.stop(serverID: harness.config.id)
        harness.finish()
        let states = await collected.value
        #expect(states.contains(.starting))
        #expect(states.contains(.ready))
        #expect(states.last == .stopped)
    }

    @Test func environmentIsNotInherited() async throws {
        setenv("PARLEY_TEST_INHERITED", "fake-value", 1)
        defer { unsetenv("PARLEY_TEST_INHERITED") }
        try await withServer(env: ["PARLEY_TEST_GIVEN": "given-value"]) { harness in
            let inherited = try await harness.call("env", ["name": .string("PARLEY_TEST_INHERITED")])
            #expect(inherited.text == "(unset)")
            let given = try await harness.call("env", ["name": .string("PARLEY_TEST_GIVEN")])
            #expect(given.text == "given-value")
        }
    }

    @Test func secretsStayOutOfSnapshotsAndLogs() async throws {
        try await withServer(env: ["PARLEY_TEST_TOKEN": "fake-token-value"]) { harness in
            let state = await snapshot(harness)
            #expect(!String(describing: state).contains("fake-token-value"))
            let logs = await harness.manager.logs(serverID: harness.config.id)
            #expect(!logs.joined().contains("fake-token-value"))
        }
    }
}

private final class MCPStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?

    var value: Int32? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        stored = status
    }
}
