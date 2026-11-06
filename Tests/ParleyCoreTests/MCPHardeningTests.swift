import Darwin
import Foundation
import Testing
@testable import ParleyCore

// What the review of the first MCP version found. Most of these used to end the whole process, so a
// regression here shows up as a crashed test run, not as a failed expectation.

/// Runs `body` on a thread with the stack the stdio reader has.
private func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

private func nested(_ kind: String, _ depth: Int) -> String {
    kind == "array"
        ? String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        : String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
}

@Suite struct JSONRangeTests {
    @Test func aNumberThatParsesToInfinityIsRefused() throws {
        #expect(JSONValue(jsonText: #"{"n":-1e999}"#) == nil)
        #expect(JSONValue(jsonText: #"{"n":1e999}"#) == nil)
        #expect(ToolArguments.parse(#"{"n":-1e999}"#) == nil)
        #expect(ToolArguments.problem(#"{"n":-1e999}"#) == "not valid JSON")
        #expect(MCPWire.decode(Data(#"{"jsonrpc":"2.0","id":1,"result":{"n":-1e999}}"#.utf8)) == nil)
    }

    @Test func writingANumberJSONCannotHoldNeverRaises() {
        for number in [Double.infinity, -.infinity, .nan] {
            let value = JSONValue.object(["n": .double(number)])
            #expect(value.sortedJSONText == #"{"n":null}"#)
            #expect(value.prettyJSONText.contains("null"))
            #expect(!MCPWire.encode(MCPOutbound(id: 1, method: "tools/call", params: value)).isEmpty)
        }
    }

    @Test func aToolDefinitionWithInfinityCannotReachTheFingerprint() {
        // The constructor fingerprints; this used to be where a server's tools/list killed the app.
        let schema = JSONValue.object(["minimum": .double(-.infinity)])
        #expect(!MCPTool(name: "t", inputSchema: schema).fingerprint.isEmpty)
    }

    @Test func objectArgumentsThatCannotBeJSONDoNotBecomeACallWithNoArguments() throws {
        let chunk = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"x","arguments":{"n":-1e999}}}]}}]}"#
        let delta = try #require(try ChunkParser.parse(chunk))
        let call = try #require(delta.toolCalls.first)
        #expect(ToolArguments.parse(try #require(call.arguments)) == nil)
    }

    @Test func aStructuredResultWithInfinityIsRefusedBeforeProjection() {
        #expect(JSONValue(jsonText: #"{"content":[],"structuredContent":{"n":-1e999}}"#) == nil)
    }

    @Test func integersPastInt64AreNotWrapped() throws {
        func number(_ text: String) -> JSONValue? { JSONValue(jsonText: #"{"n":\#(text)}"#)?["n"] }
        #expect(number("9223372036854775807") == .int(.max))
        #expect(number("-9223372036854775808") == .int(.min))
        #expect(number("18446744073709551615") == .double(18446744073709551615))
        #expect(number("9223372036854775808") == .double(9223372036854775808))
        #expect(number("1") == .int(1))
        #expect(number("1.5") == .double(1.5))
        let huge = try #require(number("123456789012345678901234567890"))
        if case .double(let value) = huge { #expect(value > 1e29) } else { Issue.record("not a double: \(huge)") }
    }

    @Test func depthIsCountedInBytesAndOutsideStrings() throws {
        #expect(JSONValue(jsonText: nested("array", JSONValue.maxDepth)) != nil)
        #expect(JSONValue(jsonText: nested("array", JSONValue.maxDepth + 1)) == nil)
        #expect(JSONValue(jsonText: nested("object", JSONValue.maxDepth + 1)) == nil)
        let inString = "\"" + String(repeating: "[", count: 1000) + "\\\"" + String(repeating: "{", count: 1000) + "\""
        #expect(JSONValue(jsonText: inString) != nil)
        #expect(!JSONValue.nestsTooDeep(Data(inString.utf8)))
    }

    @Test func parsedValuesAreLimitedToo() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(nested("array", 300).utf8))
        #expect(JSONValue(any: parsed) == nil)
    }

    @Test(arguments: ["array", "object"], [505, 511, 2000])
    func deepMessagesOnASmallStack(kind: String, depth: Int) async {
        let body = #"{"jsonrpc":"2.0","id":1,"result":"# + nested(kind, depth) + "}"
        #expect(await onSmallStack { MCPWire.decode(Data(body.utf8)) == nil })
        #expect(await Task.detached { MCPWire.decode(Data(body.utf8)) == nil }.value)
    }

    @Test(arguments: ["array", "object"])
    func anSSEPayloadThatDeepNeverReachesTheParser(kind: String) async {
        let line = "data: " + #"{"jsonrpc":"2.0","id":1,"result":"# + nested(kind, 511) + "}"
        let survived = await onSmallStack { () -> Bool in
            var decoder = SSEDecoder()
            _ = decoder.feed(line: line)
            _ = decoder.feed(line: "")
            return true
        }
        #expect(survived)
    }

    @Test func oneBadItemDoesNotLoseABatch() throws {
        let text = #"[{"jsonrpc":"2.0","id":1,"result":{}},"junk"]"#
        let messages = try #require(MCPWire.decode(Data(text.utf8)))
        #expect(messages.count == 1)
        #expect(MCPWire.decode(Data(#"["junk"]"#.utf8)) == nil)
        #expect(MCPWire.decode(Data("[]".utf8))?.isEmpty == true)
    }
}

@Suite struct MCPErrorTextTests {
    @Test func whatIsSavedCarriesNoStderrAndNoFolders() {
        let token = "sk-live-SECRET"
        for error in [MCPError.exited(status: 1, stderrTail: ["fatal: \(token)"]),
                      .startupTimedOut(seconds: 5, stderrTail: [token])] {
            #expect(error.errorDescription?.contains(token) == true, "Settings still shows it")
            #expect(!error.summary.contains(token))
            #expect(error.summary.contains("See its log in Settings > MCP."))
        }
        let missing = MCPError.commandNotFound(name: "npx", searched: ["/Users/me/bin", "/opt/homebrew/bin"])
        #expect(missing.errorDescription?.contains("/Users/me/bin") == true)
        #expect(missing.summary == "Could not find npx (it comes with Node.js). Install it, or give its full path in Settings > MCP.")
        let path = MCPError.commandNotFound(name: "/Users/me/bin/tool", searched: ["/Users/me/bin"])
        #expect(!path.summary.contains("/Users"))
        #expect(!MCPError.notExecutable("/Users/me/x").summary.contains("/Users"))
    }

    @Test func aWholeCommandLineGetsAdvice() {
        let error = MCPError.commandNotFound(name: "npx -y @scope/server /Users/me", searched: ["/Users/me/npx -y"])
        #expect(error.errorDescription == "The command contains spaces. Put the program in Command and the rest under Arguments.")
        #expect(error.summary == error.errorDescription)
    }

    @Test func aRealPathWithASpaceIsNotCalledACommandLine() {
        let error = MCPError.commandNotFound(name: "/Applications/My Tool/run", searched: ["/Applications/My Tool"])
        #expect(error.errorDescription?.hasPrefix("Could not find /Applications/My Tool/run.") == true)
    }

    @Test func aProgramThatExitsCleanlyMayNotBeAServer() {
        #expect(MCPError.exited(status: 0, stderrTail: []).errorDescription?.contains("may not be an MCP server") == true)
    }

    @Test func aFileThatCannotRunIsNotCalledMissing() async throws {
        let resolver = mcpTestResolver()
        await #expect(throws: MCPError.notExecutable("/etc/hosts")) {
            _ = try await resolver.resolve("/etc/hosts", overridePATH: nil)
        }
    }
}

@Suite struct MCPToolNameTests {
    private func parse(_ names: [String]) -> MCPToolList {
        MCPClient.parse(names.map { .object(["name": .string($0)]) }, overHTTP: false, ttl: nil, era: .legacy)
    }

    @Test func namesThatCouldFakeTheCardAreHidden() {
        let list = parse(["ok", "two\nlines", "tab\tbed", "with space", "bidi\u{202E}", "zero\u{200B}width", "tag\u{E0041}",
                          String(repeating: "x", count: 129)])
        #expect(list.tools.map(\.name) == ["ok"])
        #expect(list.hidden.count == 7)
        #expect(list.hidden.allSatisfy { $0.reason.contains("name") })
        #expect(list.hidden.allSatisfy { $0.name.unicodeScalars.count <= 128 })
    }

    @Test func namesOutsideTheSpecsPatternStillWork() {
        #expect(parse(["github:list", "a/b", "read_file", "a.b-c", String(repeating: "x", count: 128), "读取"]).hidden.isEmpty)
    }
}

@Suite struct ToolCallAccumulatorEdgeTests {
    private func calls(_ deltas: [ToolCallDelta]) -> [String] {
        var accumulator = ToolCallAccumulator()
        deltas.forEach { accumulator.apply($0) }
        return accumulator.finalCalls().map { "\($0.name) \($0.arguments)" }
    }

    @Test func wholeCallsWithoutIDsOrIndexesStayApart() {
        #expect(calls([.init(name: "a", arguments: "{}"), .init(name: "b", arguments: "{}")]) == ["a {}", "b {}"])
    }

    @Test func wholeCallsAllNumberedZeroStayApart() {
        #expect(calls([.init(index: 0, name: "a", arguments: "{}"), .init(index: 0, name: "b", arguments: "{}")]) == ["a {}", "b {}"])
    }

    @Test func aRepeatedNameInOneCallIsNotDoubled() {
        #expect(calls([.init(index: 0, id: "x", name: "a", arguments: "{"), .init(index: 0, name: "a", arguments: "}")]) == ["a {}"])
    }

    @Test func aNewIDAndNameBeforeArgumentsOpenAnotherCall() {
        #expect(calls([.init(index: 0, id: "x", name: "a", arguments: ""), .init(index: 0, id: "y", name: "b", arguments: "")]) == ["a ", "b "])
    }

    @Test func llamaCppResendingTheIDAndAGrownNameIsTheSameCall() {
        #expect(calls([.init(index: 0, id: "x", name: "read"), .init(index: 0, id: "y", name: "read_file", arguments: "{}")]) == ["read_file {}"])
    }

    @Test func nameFragmentsStillJoin() {
        #expect(calls([.init(index: 0, name: "read"), .init(index: 0, name: "_file"), .init(index: 0, arguments: "{}")]) == ["read_file {}"])
    }
}

@Suite struct MCPTimeoutClampTests {
    @Test func aHugeTimeoutIsClamped() {
        let config = MCPServerConfig(name: "x", startupTimeout: 1e30, callTimeout: 1e30)
        #expect(config.effectiveCallTimeout == MCPServerConfig.maxTimeout)
        #expect(config.effectiveStartupTimeout == MCPServerConfig.maxTimeout)
    }
}

@Suite struct MCPImportReviewTests {
    private func one(_ text: String) throws -> MCPImportEntry {
        try #require(try MCPConfigImport.parse(text).first)
    }

    @Test func variablesThatChangeWhatRunsAreShownWithTheirValues() throws {
        let entry = try one(#"{"command":"npx","args":["-y","@acme/good"],"cwd":"/tmp/evil","env":{"PATH":"/tmp/evil-bin:/usr/bin","NODE_OPTIONS":"--require /tmp/evil.js","DYLD_INSERT_LIBRARIES":"/tmp/evil.dylib","API_KEY":"secret"}}"#)
        #expect(entry.config.workingDirectory == "/tmp/evil")
        #expect(entry.danger.contains("Sets PATH=/tmp/evil-bin:/usr/bin, which changes what code runs."))
        #expect(entry.danger.contains("Sets NODE_OPTIONS=--require /tmp/evil.js, which changes what code runs."))
        #expect(entry.danger.contains("Sets DYLD_INSERT_LIBRARIES=/tmp/evil.dylib, which changes what code runs."))
        #expect(!entry.danger.joined().contains("secret"), "an ordinary value stays hidden")
        #expect(MCPConfigImport.changesWhatRuns("PATH") && !MCPConfigImport.changesWhatRuns("API_KEY"))
    }

    @Test(arguments: ["BASH_ENV", "ENV", "ZDOTDIR", "PYTHONPATH", "PYTHONSTARTUP", "LD_PRELOAD", "NODE_PATH", "NPM_CONFIG_REGISTRY", "UV_INDEX_URL"])
    func eachVariableIsCaught(name: String) throws {
        let entry = try one(#"{"command":"x","env":{"\#(name)":"v"}}"#)
        #expect(entry.danger == ["Sets \(name)=v, which changes what code runs."])
    }

    @Test(arguments: [
        (#"{"command":"/usr/bin/sudo","args":["rm"]}"#, "Runs with sudo: the server would have administrator rights."),
        (#"{"command":"bash","args":["-ec","x"]}"#, "Runs a shell command line rather than a program."),
        (#"{"command":"/usr/bin/env","args":["bash","-c","x"]}"#, "Runs a shell command line rather than a program."),
        (#"{"command":"env","args":["A=1","-i","zsh","-lc","x"]}"#, "Runs a shell command line rather than a program."),
        (#"{"command":"python3","args":["-c","x"]}"#, "Runs code written into its arguments rather than a program."),
        (#"{"command":"/opt/homebrew/bin/node","args":["-e","x"]}"#, "Runs code written into its arguments rather than a program."),
    ])
    func commandsThatEscapedTheChecks(text: String, line: String) throws {
        #expect(try one(text).danger.contains(line))
    }

    @Test func aPlainServerRaisesNothing() throws {
        #expect(try one(#"{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/Users/me/Documents"]}"#).danger.isEmpty)
        #expect(try one(#"{"command":"python3","args":["server.py"]}"#).danger.isEmpty)
    }

    @Test func disabledInThePasteStaysOff() throws {
        let entry = try one(#"{"command":"x","disabled":true}"#)
        #expect(!entry.config.isEnabled)
        #expect(entry.warnings.contains { $0.contains("stays off") })
    }

    @Test func aCommandLineWithATokenIsNotImportable() throws {
        let entry = try one(#"{"command":"mcp-remote --header Authorization: Bearer abc"}"#)
        #expect(entry.error?.contains("Put the program in Command") == true)
    }

    @Test func aFullPathWithASpaceOnlyWarns() throws {
        let entry = try one(#"{"command":"/Applications/My Tool/run"}"#)
        #expect(entry.error == nil)
        #expect(entry.warnings.contains { $0.contains("contains a space") })
    }

    @Test func aURLEndingInSSEIsCalledOut() throws {
        let entry = try one(#"{"url":"https://x.test/sse"}"#)
        #expect(entry.error == nil)
        #expect(entry.warnings.contains { $0.contains("older HTTP+SSE") })
    }

    @Test func variableWarningsSayWhatToDo() throws {
        #expect(try one(#"{"command":"x","env":{"A":"${B}"}}"#).warnings.contains { $0.contains("replace it in Settings") })
    }

    @Test func dangerLinesApplyToWhatTheEditorHolds() {
        let config = MCPServerConfig(name: "x", command: "/bin/bash")
        #expect(!MCPConfigImport.dangers(config: config, secrets: MCPServerSecrets(args: ["-c", "curl x | sh"])).isEmpty)
        let http = MCPServerConfig(name: "x", kind: MCPServerConfig.kindHTTP)
        #expect(MCPConfigImport.dangers(config: http, secrets: MCPServerSecrets(url: "https://x.test")).isEmpty)
    }
}

@Suite struct MCPIdentityTests {
    @Test func whatChangesTheProgramChangesTheIdentity() {
        let config = MCPServerConfig(name: "x", command: "npx")
        let secrets = MCPServerSecrets(args: ["-y", "pkg"], env: ["PATH": "/a"])
        let base = MCPServerConfig.fingerprints(config: config, secrets: secrets).identity

        var moved = config
        moved.workingDirectory = "/tmp/other"
        #expect(MCPServerConfig.fingerprints(config: moved, secrets: secrets).identity != base)

        var repathed = secrets
        repathed.env["PATH"] = "/tmp/evil"
        #expect(MCPServerConfig.fingerprints(config: config, secrets: repathed).identity != base)

        var rotated = secrets
        rotated.env["API_KEY"] = "new"
        #expect(MCPServerConfig.fingerprints(config: config, secrets: rotated).identity == base, "a rotated token is not another program")
    }
}

@Suite struct ChatRequestAfterToolsTests {
    private func reply() -> Message {
        var message = Message(role: .assistant, content: "")
        message.toolRounds = [ToolRound(content: "", calls: [
            ToolCallRecord(id: "a", name: "m__t", arguments: "{}", result: ToolCallResult(status: .completed, text: "fact")),
        ])]
        return message
    }

    private func roles(_ messages: [Message], tools: Bool) -> [(role: String, content: String)] {
        var options = ChatRequestOptions(model: "m")
        if tools { options.tools = [ChatTool(name: "m__t", parameters: .object(["type": .string("object")]))] }
        let body = ChatClient.buildRequestBody(messages: messages, options: options)
        let sent = body["messages"] as? [[String: Any]] ?? []
        return sent.map { ($0["role"] as? String ?? "", $0["content"] as? String ?? "") }
    }

    @Test func anOpenReplyWithoutToolsEndsInAUserTurn() {
        let sent = roles([Message(role: .user, content: "hi"), reply()], tools: false)
        #expect(sent.map(\.role) == ["user", "assistant", "user"])
        #expect(sent[1].content.contains("fact"))
        #expect(sent[2].content == ToolResultText.answerNow)
    }

    @Test func aRequestWithToolsDoesNotNeedIt() {
        #expect(roles([Message(role: .user, content: "hi"), reply()], tools: true).map(\.role) == ["user", "assistant", "tool"])
    }

    @Test func anEarlierReplyAddsNothing() {
        let sent = roles([Message(role: .user, content: "hi"), reply(), Message(role: .user, content: "and?")], tools: false)
        #expect(sent.map(\.role) == ["user", "assistant", "user"])
        #expect(sent[2].content == "and?")
    }

    @Test func aPlainAssistantLastAddsNothing() {
        let sent = roles([Message(role: .user, content: "hi"), Message(role: .assistant, content: "yes")], tools: false)
        #expect(sent.map(\.role) == ["user", "assistant"])
    }
}

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPStopAndCrashTests {
    /// The tool list of a harness whose server this test then stops.
    private func started(_ behaviors: [String] = []) async throws -> (MCPStdioHarness, MCPToolBinding, pid_t) {
        let harness = try MCPStdioHarness(behaviors: behaviors)
        let catalog = await harness.catalog()
        let binding = try harness.binding("echo", in: catalog)
        return (harness, binding, try #require(harness.pid))
    }

    @Test func aToolCallDoesNotRestartWhatTheUserStopped() async throws {
        let (harness, binding, pid) = try await started()
        defer { harness.finish() }
        await harness.manager.stop(serverID: harness.config.id)
        #expect(await eventually { processIsGone(pid) })

        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .notCalled)
        #expect(result.text == "The tool was not called: This server was stopped.")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.pid == pid, "no new process")
    }

    @Test func aNewReplyStartsItAgain() async throws {
        let (harness, binding, pid) = try await started()
        defer { harness.finish() }
        await harness.manager.stop(serverID: harness.config.id)
        #expect(await harness.catalog().bindings.isEmpty == false)
        #expect(harness.pid != pid)
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .completed)
    }

    @Test func connectStartsItAgain() async throws {
        let (harness, binding, _) = try await started()
        defer { harness.finish() }
        await harness.manager.stop(serverID: harness.config.id)
        _ = await harness.manager.connect(harness.config)
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .completed)
    }

    @Test func aRemovedServerStaysGone() async throws {
        let (harness, binding, pid) = try await started()
        defer { harness.finish() }
        try harness.store.deleteSecrets(for: harness.config.id)
        await harness.manager.clearLogs(serverIDs: [])
        await harness.manager.forget(serverID: harness.config.id)
        #expect(await eventually { processIsGone(pid) })

        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .notCalled)
        #expect(await harness.manager.logs(serverID: harness.config.id).isEmpty)

        // A catalog that was still on its way, with the old config.
        let late = await harness.catalog()
        #expect(late.bindings.isEmpty)
        #expect(late.unavailable.first?.reason == MCPError.notConfigured.errorDescription)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.pid == pid, "nothing was started without its secrets")
    }

    @Test func aCrashStillRestartsOnTheNextCall() async throws {
        let (harness, binding, pid) = try await started()
        defer { harness.finish() }
        kill(pid, SIGKILL)
        #expect(await eventually { processIsGone(pid) })
        try await Task.sleep(nanoseconds: 200_000_000)
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .completed)
        #expect(harness.pid != pid)
    }

    @Test func aServerThatLeavesRightAfterListingIsNotLeftReadyAndDead() async throws {
        // A race, so several times: it used to land on the bad side about once in twenty. The mock
        // leaves only the first time, so a later use has to start it again and work.
        for _ in 0..<15 {
            let harness = try MCPStdioHarness(behaviors: ["exit-after-first-list"])
            defer { harness.finish() }
            _ = await harness.catalog()
            try await Task.sleep(nanoseconds: 80_000_000)
            let later = await harness.catalog()
            #expect(!later.bindings.isEmpty, "wedged on a dead client: \(later.unavailable)")
        }
    }

    @Test func stdoutClosingWhileTheProcessRunsEndsTheConnection() async throws {
        let (harness, binding, _) = try await started(["close-stdout-after-list"])
        defer { harness.finish() }
        let started = Date()
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 20, maxCharacters: 1000)
        #expect(result.callStatus != .completed)
        #expect(Date().timeIntervalSince(started) < 5, "it must not wait out the timeout")
    }

    @Test func aDeepAnswerFailsTheCallAtOnce() async throws {
        let (harness, binding, _) = try await started(["deep-result"])
        defer { harness.finish() }
        let started = Date()
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 20, maxCharacters: 1000)
        #expect(result.callStatus == .failed)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aSchemaWithInfinityFailsTheServerNotTheApp() async throws {
        let harness = try MCPStdioHarness(behaviors: ["neg-inf-schema"], startupTimeout: 5)
        defer { harness.finish() }
        let started = Date()
        let catalog = await harness.catalog()
        #expect(catalog.bindings.isEmpty)
        #expect(catalog.unavailable.first?.reason.contains("number out of range") == true)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aRejectionWithANullIDAnswersTheOneRequestWaiting() async throws {
        let (harness, binding, _) = try await started(["null-id-error"])
        defer { harness.finish() }
        let started = Date()
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 20, maxCharacters: 1000)
        #expect(result.callStatus == .failed)
        #expect(result.text.contains("Invalid request"))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aHugeTimeoutDoesNotTrap() async throws {
        let (harness, binding, _) = try await started()
        defer { harness.finish() }
        let result = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 1e30, maxCharacters: 1000)
        #expect(result.callStatus == .completed)
    }
}

@Suite(.serialized)
struct MCPStderrTests {
    /// A server that fails at start, after printing a token to stderr.
    private func failing(script: String = "echo 'fatal: token=sk-live-SECRET' >&2; exit 1") throws
        -> (MCPConnectionManager, MCPServerConfig, InMemoryMCPSecretStore) {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "test", stopGrace: 0.2)
        let config = MCPServerConfig(name: "Bad", command: "/bin/sh", startupTimeout: 5)
        try store.setSecrets(MCPServerSecrets(args: ["-c", script]), for: config.id)
        return (manager, config, store)
    }

    @Test func theReasonForAConversationNeverCarriesStderr() async throws {
        let (manager, config, _) = try failing()
        defer { manager.shutdownSync(grace: 0.2) }
        let catalog = await manager.catalog(for: [config])
        let reason = try #require(catalog.unavailable.first?.reason)
        #expect(!reason.contains("SECRET"))
        #expect(reason.contains("See its log in Settings > MCP."))
    }

    @Test func aMissingProgramNamesNoFolders() async throws {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "test", stopGrace: 0.2)
        defer { manager.shutdownSync(grace: 0.2) }
        let config = MCPServerConfig(name: "Gone", command: "definitely-not-a-program", startupTimeout: 5)
        let catalog = await manager.catalog(for: [config])
        #expect(catalog.unavailable.first?.reason == "Could not find definitely-not-a-program. Install it, or give its full path in Settings > MCP.")
    }

    @Test func settingsKeepsItUntilLock() async throws {
        let (manager, config, _) = try failing()
        defer { manager.shutdownSync(grace: 0.2) }
        let states = StateLog()
        let updates = manager.updates
        let reader = Task { for await snapshot in updates { states.add(snapshot.state) } }
        defer { reader.cancel() }
        _ = await manager.catalog(for: [config])
        #expect(await eventually { states.failure?.contains("SECRET") == true })

        await manager.clearLogs(serverIDs: [config.id])
        #expect(await eventually { states.failure?.contains("See its log") == true })
        #expect(states.failure?.contains("SECRET") == false)
        #expect(await manager.logs(serverID: config.id).isEmpty)
    }

    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var last: MCPServerState?

        func add(_ state: MCPServerState) {
            lock.lock(); defer { lock.unlock() }
            last = state
        }

        /// The text of the latest `.failed`.
        var failure: String? {
            lock.lock(); defer { lock.unlock() }
            if case .failed(let text)? = last { return text }
            return nil
        }
    }
}

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPHTTPCloseTests {
    @Test(arguments: ["legacy", "modern"])
    func stoppingDuringACallDoesNotCrash(era: String) async throws {
        let harness = try await MCPHTTPHarness(era: era)
        defer { harness.finish() }
        let catalog = await harness.catalog()
        let binding = try #require(catalog.bindings.first { $0.tool.name == "slow" })
        let call = Task { await harness.manager.call(binding, arguments: ["seconds": .int(5)], timeout: 10, maxCharacters: 1000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await harness.manager.stop(serverID: harness.config.id)
        let result = await call.value
        #expect(result.callStatus == .cancelled || result.callStatus == .failed, "\(result.status)")
        // The detached notifications/cancelled has its turn here.
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @Test func quittingDuringACallDoesNotCrash() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy", behaviors: ["session"])
        let catalog = await harness.catalog()
        let binding = try #require(catalog.bindings.first { $0.tool.name == "slow" })
        let call = Task { await harness.manager.call(binding, arguments: ["seconds": .int(5)], timeout: 10, maxCharacters: 1000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        harness.finish()
        _ = await call.value
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test func aClosedTransportRefusesEverything() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy")
        defer { harness.finish() }
        let transport = MCPHTTPTransport(url: try #require(URL(string: harness.url)), headers: [:], registry: nil)
        await transport.close(grace: 0)
        await #expect(throws: MCPError.streamEnded) {
            _ = try await transport.send(MCPOutbound(id: 1, method: "tools/list", params: .object([:])))
        }
        await #expect(throws: MCPError.streamEnded) {
            try await transport.notify(MCPOutbound(method: "notifications/cancelled", params: .object([:])))
        }
        await #expect(throws: MCPError.streamEnded) {
            try await transport.respond(to: .int(1), result: .object([:]), error: nil, headers: [:])
        }
    }

    @Test func aListingInFlightDuringStop() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy", behaviors: ["sse"])
        defer { harness.finish() }
        for _ in 0..<15 {
            async let listed = harness.catalog()
            await harness.manager.stop(serverID: harness.config.id)
            _ = await listed
        }
    }

    @Test func aServerThatNeverAnswersInitializedFailsTheStart() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy", behaviors: ["hang-initialized"])
        defer { harness.finish() }
        harness.config.startupTimeout = 1
        let started = Date()
        let catalog = await harness.catalog()
        #expect(catalog.bindings.isEmpty)
        #expect(catalog.unavailable.first?.reason.contains("did not answer within 1 seconds") == true)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aSessionWhoseRecoveryFailedIsRecoveredLater() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy", behaviors: ["session"])
        defer { harness.finish() }
        let catalog = await harness.catalog()
        let binding = try #require(catalog.bindings.first { $0.tool.name == "echo" })
        try await harness.expireSessions()
        try await harness.refuseInitialize()
        let failed = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(failed.callStatus == .failed)
        let recovered = await harness.manager.call(binding, arguments: ["text": .string("x")], timeout: 5, maxCharacters: 1000)
        #expect(recovered.callStatus == .completed, "\(recovered.text)")
    }

    @Test func carriageReturnLineEndsInAnEventStream() async throws {
        let harness = try await MCPHTTPHarness(era: "legacy", behaviors: ["sse-cr"])
        defer { harness.finish() }
        let result = try await harness.call("echo", ["text": .string("hi")], timeout: 5)
        #expect(result.callStatus == .completed)
        #expect(result.text.contains("hi"))
    }
}
