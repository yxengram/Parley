import Foundation
import Testing
@testable import ParleyCore

// The built-in tools as the reply loop sees them: definitions, the synthetic server, the router, and
// the calculator and clock, which need no disk or network. Files and fetch have suites of their own.

/// Records everything it is asked. A built-in-only conversation must leave `events` empty.
private final class RecordingHost: MCPToolHost, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var catalogServers: [[MCPServerConfig]] = []
    let tools: [MCPTool]
    let updates: AsyncStream<MCPServerSnapshot>
    private let continuation: AsyncStream<MCPServerSnapshot>.Continuation

    init(tools: [MCPTool] = [MCPTool(name: "echo", description: "Echoes.", inputSchema: .object(["type": .string("object")]))]) {
        self.tools = tools
        (updates, continuation) = AsyncStream.makeStream(of: MCPServerSnapshot.self)
    }

    private func note(_ event: String) { lock.withLock { recorded.append(event) } }
    var events: [String] { lock.withLock { recorded } }
    var catalogs: [[MCPServerConfig]] { lock.withLock { catalogServers } }

    func catalog(for servers: [MCPServerConfig]) async -> MCPToolCatalog {
        note("catalog")
        lock.withLock { catalogServers.append(servers) }
        return MCPToolCatalog(bindings: MCPToolNamer.assign(servers.map { ($0, tools) }),
                              unavailable: [MCPServerFailure(name: "down", reason: "no")])
    }

    func call(_ binding: MCPToolBinding, arguments: [String: JSONValue], timeout: TimeInterval, maxCharacters: Int) async -> ToolCallResult {
        note("call \(binding.tool.name)")
        return ToolCallResult(status: .completed, text: "from the real host")
    }

    func connect(_ server: MCPServerConfig) async -> MCPServerSnapshot {
        note("connect")
        return MCPServerSnapshot(serverID: server.id)
    }

    func stop(serverID: UUID) async { note("stop") }
    func forget(serverID: UUID) async { note("forget") }
    func logs(serverID: UUID) async -> [String] { note("logs"); return ["line"] }
    func clearLogs(serverIDs: [UUID]) async { note("clearLogs \(serverIDs.count)") }
    func shutdownSync(grace: TimeInterval) { note("shutdown") }
    func signOut(serverID: UUID) async throws { note("signOut") }
    func forgetSignIn(serverID: UUID) async { note("forgetSignIn") }
    func signInInfo(serverID: UUID) async -> MCPSignInInfo? { note("signInInfo"); return nil }
}

/// Settings a test can change between calls, as the Settings window does.
final class BuiltInSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BuiltInToolSettings

    init(_ value: BuiltInToolSettings) { self.value = value }

    var current: BuiltInToolSettings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func allOn(folder: String? = "/some/folder") -> BuiltInToolSettings {
    BuiltInToolSettings(enabled: BuiltInTools.Tool.allCases.map(\.rawValue), folderPath: folder)
}

private func binding(_ tool: BuiltInTools.Tool) throws -> MCPToolBinding {
    let config = try #require(BuiltInTools.serverConfig(allOn()))
    return try #require(BuiltInTools.bindings(for: config).first { $0.tool.name == tool.rawValue })
}

/// A router over `host`, with the settings in `box`.
private func router(_ host: MCPToolHost, _ box: BuiltInSettingsBox, now: Date = Date(), zone: TimeZone = .current) -> BuiltInToolRouter {
    BuiltInToolRouter(wrapping: host, runner: BuiltInToolRunner(settings: { box.current }, now: { now }, timeZone: { zone }))
}

private func calculate(_ text: String) throws -> Double {
    try BuiltInCalculator.evaluate(text)
}

@Suite struct BuiltInDefinitionTests {
    @Test func theToolsAreTheFiveOfTheDesign() {
        #expect(BuiltInTools.definitions.map(\.name) == ["current_time", "calculate", "list_files", "read_file", "fetch_url"])
    }

    @Test func nothingIsOnByDefault() {
        #expect(BuiltInToolSettings().effectiveTools.isEmpty)
        #expect(BuiltInTools.serverConfig(.off) == nil)
    }

    @Test func aFileToolNeedsAFolder() {
        let names = [BuiltInTools.Tool.listFiles.rawValue, BuiltInTools.Tool.readFile.rawValue]
        #expect(BuiltInToolSettings(enabled: names).effectiveTools.isEmpty)
        #expect(BuiltInToolSettings(enabled: names, folderPath: "").effectiveTools.isEmpty)
        #expect(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: names)) == nil)
        #expect(BuiltInToolSettings(enabled: names, folderPath: "/a").effectiveTools == [.listFiles, .readFile])
    }

    @Test func aNameOnlyALaterVersionKnowsIsIgnored() {
        let settings = BuiltInToolSettings(enabled: ["shell", "calculate"])
        #expect(settings.effectiveTools == [.calculate])
        #expect(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: ["shell"])) == nil)
    }

    @Test func theServerListsWhatIsOffAsDisabled() throws {
        let config = try #require(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: ["calculate"])))
        #expect(config.id == BuiltInTools.serverID)
        #expect(config.kind == MCPServerConfig.kindBuiltIn)
        #expect(config.name == "Parley")
        #expect(config.isEnabled)
        #expect(config.disabledTools == ["current_time", "list_files", "read_file", "fetch_url"])
        #expect(BuiltInTools.bindings(for: config).map(\.exposedName) == ["builtin__calculate"])
    }

    @Test func theFileAndNetworkToolsAskEveryTime() throws {
        #expect(!BuiltInTools.asksEveryTime(try binding(.currentTime)))
        #expect(!BuiltInTools.asksEveryTime(try binding(.calculate)))
        #expect(BuiltInTools.asksEveryTime(try binding(.listFiles)))
        #expect(BuiltInTools.asksEveryTime(try binding(.readFile)))
        #expect(BuiltInTools.asksEveryTime(try binding(.fetchURL)))
        let real = MCPToolBinding(exposedName: "a__b", serverID: UUID(), serverName: "a",
                                  tool: MCPTool(name: "read_file", inputSchema: .object([:])))
        #expect(!BuiltInTools.asksEveryTime(real))
    }

    @Test func definitionsHoldNothingOfTheUser() {
        let text = BuiltInTools.definitions.map { ($0.description ?? "") + $0.inputSchema.sortedJSONText }.joined()
        #expect(!text.contains("/Users"))
        #expect(!text.contains(NSUserName()))
    }

    @Test func theSchemasAreObjects() {
        for tool in BuiltInTools.definitions {
            #expect(tool.inputSchema["type"]?.stringValue == "object")
            #expect(tool.inputSchema["properties"] != nil)
        }
    }

    @Test func theCardSaysWhatACallTouches() {
        #expect(BuiltInTools.approvalDetail(toolName: "calculate", arguments: [:], folderPath: "/a/Notes") == "Built-in tool")
        #expect(BuiltInTools.approvalDetail(toolName: "read_file", arguments: [:], folderPath: "/a/Notes") == "Built-in tool, in folder Notes")
        #expect(BuiltInTools.approvalDetail(toolName: "read_file", arguments: ["path": .string("a/b.txt")], folderPath: "/a/Notes")
            == "Built-in tool, in folder Notes: a/b.txt")
        #expect(BuiltInTools.approvalDetail(toolName: "list_files", arguments: ["path": .string("a")], folderPath: "/a/Notes")
            == "Built-in tool, in folder Notes: a")
        // What is read is `path`, whatever else the model sends.
        #expect(BuiltInTools.approvalDetail(toolName: "read_file", arguments: ["file": .string("decoy"), "path": .int(1)], folderPath: "/a/Notes")
            == "Built-in tool, in folder Notes")
        #expect(BuiltInTools.approvalDetail(toolName: "list_files", arguments: [:], folderPath: nil) == "Built-in tool")
        #expect(BuiltInTools.approvalDetail(toolName: "fetch_url", arguments: ["url": .string("https://Example.org/a?b=c")], folderPath: nil)
            == "Built-in tool, contacts Example.org")
        #expect(BuiltInTools.approvalDetail(toolName: "fetch_url", arguments: ["url": .string("ftp://a.b/")], folderPath: nil) == "Built-in tool")
    }
}

@Suite struct BuiltInStoredFieldTests {
    @Test func aConversationWithoutTheOptOutEncodesNoKey() throws {
        let data = try JSONEncoder().encode(ConversationSettings(model: "m"))
        #expect(!String(decoding: data, as: UTF8.self).contains("builtInToolsOff"))
    }

    @Test func turningTheCheckboxBackOnLeavesNoKey() throws {
        var settings = ConversationSettings(model: "m")
        #expect(settings.usesBuiltInTools)
        settings.usesBuiltInTools = false
        #expect(settings.builtInToolsOff == true)
        #expect(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("builtInToolsOff"))
        settings.usesBuiltInTools = true
        #expect(settings.builtInToolsOff == nil)
        #expect(!String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("builtInToolsOff"))
    }

    @Test func anOlderFileDecodesAndTheOptOutRoundTrips() throws {
        let old = try JSONDecoder().decode(ConversationSettings.self, from: Data(#"{"model":"m","systemPrompt":""}"#.utf8))
        #expect(old.builtInToolsOff == nil)
        var settings = ConversationSettings(model: "m")
        settings.builtInToolsOff = true
        let back = try JSONDecoder().decode(ConversationSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.builtInToolsOff == true)
    }

    @Test func aStoredServerOfThisKindStillDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"builtin","later":1}"#
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8)).kind == "builtin")
    }
}

@Suite struct BuiltInNamerTests {
    private func names(_ server: String, id: UUID = UUID()) -> [String] {
        let config = MCPServerConfig(id: id, name: server)
        return MCPToolNamer.assign([(config, [MCPTool(name: "read_file", inputSchema: .object([:]))])]).map(\.exposedName)
    }

    /// What it was called before the built-in tools existed: its names must not depend on them.
    @Test func aServerCalledBuiltinKeepsItsNames() throws {
        let id = try #require(UUID(uuidString: "ABCD0000-0000-0000-0000-000000000000"))
        #expect(names("Builtin", id: id) == ["builtin__read_file"])
        #expect(names("BUILTIN!", id: id) == ["builtin__read_file"])
        #expect(names("builtin", id: id) == ["builtin__read_file"])
    }

    @Test func aBuiltInMovesAsideOnlyForTheNameThatClashes() throws {
        let config = try #require(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: ["calculate", "current_time"])))
        let names = BuiltInTools.bindings(for: config, avoiding: ["builtin__calculate"]).map(\.exposedName)
        #expect(names == ["builtin__current_time", "builtin___parley_calculate"])
    }

    @Test func otherNamesAreUntouched() {
        #expect(names("Built-In") == ["built_in__read_file"])
        #expect(names("BuiltIn") == ["built_in__read_file"])
        #expect(names("Mock") == ["mock__read_file"])
    }
}

@Suite struct BuiltInRouterTests {
    @Test func noRealServerMeansTheRealHostHearsNothing() async throws {
        let host = RecordingHost()
        let route = router(host, BuiltInSettingsBox(allOn()))
        let none = await route.catalog(for: [])
        #expect(none.bindings.isEmpty)

        let config = try #require(BuiltInTools.serverConfig(allOn()))
        let catalog = await route.catalog(for: [config])
        #expect(catalog.bindings.count == 5)
        _ = await route.call(try binding(.calculate), arguments: ["expression": .string("1+1")], timeout: 5, maxCharacters: 100)
        _ = await route.connect(config)
        await route.stop(serverID: config.id)
        await route.forget(serverID: config.id)
        #expect(await route.logs(serverID: config.id).isEmpty)
        await route.clearLogs(serverIDs: [config.id])
        #expect(host.events.isEmpty)
    }

    @Test func offOnlyAnEmptyCatalogAndNothingElse() async {
        let host = RecordingHost()
        let catalog = await router(host, BuiltInSettingsBox(.off)).catalog(for: [])
        #expect(catalog.chatTools.isEmpty && catalog.unavailable.isEmpty && catalog.definitionTokens == 0)
        #expect(host.events.isEmpty)
    }

    @Test func aRealServerGoesThroughUnchanged() async throws {
        let host = RecordingHost()
        let route = router(host, BuiltInSettingsBox(.off))
        let real = MCPServerConfig(name: "Mock")
        let alone = await route.catalog(for: [real])
        #expect(alone.bindings.map(\.exposedName) == ["mock__echo"])
        #expect(alone.unavailable.map(\.name) == ["down"])
        let result = await route.call(try #require(alone.bindings.first), arguments: [:], timeout: 5, maxCharacters: 100)
        #expect(result.text == "from the real host")
        #expect(host.events == ["catalog", "call echo"])
    }

    @Test func bothMergeAndTheBuiltInConfigNeverReachesTheRealHost() async throws {
        let host = RecordingHost()
        let route = router(host, BuiltInSettingsBox(allOn()))
        let real = MCPServerConfig(name: "Mock")
        let config = try #require(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: ["calculate", "current_time"])))
        let catalog = await route.catalog(for: [config, real])

        #expect(catalog.bindings.map(\.exposedName) == ["builtin__calculate", "builtin__current_time", "mock__echo"])
        #expect(catalog.chatTools.map(\.name) == catalog.bindings.map(\.exposedName))
        #expect(catalog.definitionTokens > 0)
        #expect(catalog.unavailable.map(\.name) == ["down"])
        #expect(host.catalogs.flatMap { $0 }.map(\.id) == [real.id])
    }

    @Test func aServerCalledBuiltinCanSitBesideTheBuiltIns() async throws {
        let host = RecordingHost(tools: [MCPTool(name: "calculate", inputSchema: .object(["type": .string("object")]))])
        let route = router(host, BuiltInSettingsBox(allOn()))
        let real = MCPServerConfig(id: try #require(UUID(uuidString: "ABCD0000-0000-0000-0000-000000000000")), name: "Builtin")
        let config = try #require(BuiltInTools.serverConfig(BuiltInToolSettings(enabled: ["calculate"])))
        let catalog = await route.catalog(for: [real, config])
        #expect(catalog.bindings.map(\.exposedName) == ["builtin___parley_calculate", "builtin__calculate"])
        #expect(catalog.binding(forFunctionName: "builtincalculate")?.serverID == real.id)
        #expect(catalog.binding(forFunctionName: "builtinparleycalculate")?.serverID == BuiltInTools.serverID)
        let builtIn = try #require(catalog.exactBinding(forFunctionName: "builtin___parley_calculate"))
        let result = await route.call(builtIn, arguments: ["expression": .string("6*7")], timeout: 5, maxCharacters: 100)
        #expect(result.text == "42")
        #expect(host.events == ["catalog"])
    }

    @Test func everythingElseIsForwarded() async throws {
        let host = RecordingHost()
        let route = router(host, BuiltInSettingsBox(.off))
        let id = UUID()
        _ = await route.connect(MCPServerConfig(id: id, name: "a"))
        await route.stop(serverID: id)
        await route.forget(serverID: id)
        #expect(await route.logs(serverID: id) == ["line"])
        await route.clearLogs(serverIDs: [id, BuiltInTools.serverID])
        try await route.signOut(serverID: id)
        await route.forgetSignIn(serverID: id)
        _ = await route.signInInfo(serverID: id)
        route.shutdownSync(grace: 0)
        #expect(host.events == ["connect", "stop", "forget", "logs", "clearLogs 1", "signOut", "forgetSignIn", "signInInfo", "shutdown"])
    }
}

@Suite struct BuiltInCallTests {
    @Test func aChangeInSettingsAppliesToTheNextCall() async throws {
        let box = BuiltInSettingsBox(BuiltInToolSettings(enabled: ["calculate"]))
        let route = router(RecordingHost(), box)
        let call = try binding(.calculate)
        let on = await route.call(call, arguments: ["expression": .string("2+2")], timeout: 5, maxCharacters: 100)
        #expect(on.text == "4")
        #expect(on.callStatus == .completed)

        box.current = .off
        let off = await route.call(call, arguments: ["expression": .string("2+2")], timeout: 5, maxCharacters: 100)
        #expect(off.callStatus == .notCalled)
        #expect(off.text == ToolResultText.turnedOff)
    }

    @Test func aFileToolWhoseFolderWentIsTurnedOff() async throws {
        let box = BuiltInSettingsBox(BuiltInToolSettings(enabled: ["read_file"]))
        let result = await router(RecordingHost(), box).call(try binding(.readFile), arguments: ["path": .string("a")], timeout: 5, maxCharacters: 100)
        #expect(result.callStatus == .notCalled)
        #expect(result.text == ToolResultText.turnedOff)
    }

    @Test func aFailureIsAToolErrorLikeAnMCPOne() async throws {
        let route = router(RecordingHost(), BuiltInSettingsBox(allOn()))
        let result = await route.call(try binding(.calculate), arguments: ["expression": .string("1/0")], timeout: 5, maxCharacters: 100)
        #expect(result.callStatus == .toolError)
        #expect(result.text == "The tool reported an error:\nDivision by zero.")
        #expect(result.duration != nil)
        let missing = await route.call(try binding(.calculate), arguments: [:], timeout: 5, maxCharacters: 100)
        #expect(missing.callStatus == .toolError)
    }

    @Test func aResultOverTheBudgetIsCutAsAnMCPOneIs() async throws {
        let route = router(RecordingHost(), BuiltInSettingsBox(allOn()))
        let result = await route.call(try binding(.currentTime), arguments: [:], timeout: 5, maxCharacters: 10)
        #expect(result.originalCharacters != nil)
        #expect(result.text.contains("[Truncated by Parley: showing the first 10 of"))
    }

    @Test func theClockIsLocalAndLocaleIndependent() async throws {
        // 2026-11-07 13:04:05 UTC, a Saturday.
        let date = Date(timeIntervalSince1970: 1_793_970_245 + 86400)
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let route = router(RecordingHost(), BuiltInSettingsBox(allOn()), now: date, zone: zone)
        let result = await route.call(try binding(.currentTime), arguments: [:], timeout: 5, maxCharacters: 1000)
        #expect(result.text == "Date: 2026-11-07\nTime: 21:04:05\nWeekday: Saturday\nUTC offset: +08:00\nTime zone: Asia/Shanghai")
        let utc = BuiltInToolRunner.timeText(date, zone: try #require(TimeZone(identifier: "GMT")))
        #expect(utc.contains("UTC offset: +00:00"))
    }

    @Test func anUnknownToolIsNotCalled() async {
        let runner = BuiltInToolRunner(settings: { allOn() })
        let result = await runner.call(MCPTool(name: "shell", inputSchema: .object([:])), arguments: [:], timeout: 5, maxCharacters: 100)
        #expect(result.callStatus == .notCalled)
    }
}

@Suite struct BuiltInCalculatorTests {
    @Test(arguments: [
        ("1 + 2 * 3", 7.0), ("(1 + 2) * 3", 9), ("2 ^ 3 ^ 2", 512), ("-2 ^ 2", -4), ("2 ^ -1", 0.5), ("--2", 2), ("+3", 3),
        ("7 % 3", 1), ("-7 % 3", -1), ("10 / 4", 2.5), ("1 - 2 - 3", -4), ("100 / 10 / 2", 5), ("2 * 3 % 4", 2),
        ("sqrt(16)", 4), ("abs(-3)", 3), ("floor(2.7)", 2), ("ceil(2.1)", 3), ("round(2.5)", 3), ("log(1000)", 3), ("ln(e)", 1),
        ("exp(0)", 1), ("sin(0)", 0), ("cos(0)", 1), ("tan(0)", 0), ("asin(0)", 0), ("acos(1)", 0), ("atan(0)", 0),
        ("pi", Double.pi), ("e", M_E), ("PI", Double.pi), ("Sqrt(4)", 2), ("1e3", 1000), ("2.5e-1", 0.25), (".5", 0.5), ("1.", 1),
        ("2 * pi", 2 * Double.pi), ("  1\t+\n1 ", 2), ("((((1))))", 1),
    ])
    func evaluates(_ text: String, _ expected: Double) throws {
        #expect(try abs(calculate(text) - expected) < 1e-12)
    }

    @Test(arguments: [
        ("", BuiltInCalculator.Failure.empty), ("   ", .empty), ("1/0", .divisionByZero), ("1%0", .divisionByZero),
        ("sqrt(-1)", .notFinite), ("10^400", .notFinite), ("0^-1", .notFinite), ("ln(0)", .notFinite),
        ("foo(1)", .unknownName("foo")), ("foo", .unknownName("foo")),
        ("1 +", .unexpected(position: 3)), ("(1", .unexpected(position: 2)), ("1)", .unexpected(position: 1)),
        ("2e", .unexpected(position: 1)), ("1.2.3", .unexpected(position: 3)), ("sin", .unexpected(position: 3)),
        ("sin 1", .unexpected(position: 4)), ("1 2", .unexpected(position: 2)), ("#", .unexpected(position: 0)), (".", .unexpected(position: 0)),
    ])
    func refuses(_ text: String, _ failure: BuiltInCalculator.Failure) {
        #expect(throws: failure) { try calculate(text) }
    }

    @Test func nothingLikeAFormatStringIsEverRun() {
        for text in ["FUNCTION(1, 'exit')", "$a", "%@", "'a'", "CAST(1, 'NSString')"] {
            #expect(throws: (any Error).self) { try calculate(text) }
        }
    }

    @Test func theLengthCapHolds() throws {
        let fits = "1" + String(repeating: "+1", count: 499)
        #expect(fits.count == 999)
        #expect(try calculate(fits) == 500)
        #expect(throws: BuiltInCalculator.Failure.tooLong) { try calculate(fits + "+1") }
    }

    @Test func theDepthCapHoldsForEveryWayToRecurse() {
        let deep = 400
        #expect(throws: BuiltInCalculator.Failure.tooDeep) { try calculate(String(repeating: "(", count: deep) + "1" + String(repeating: ")", count: deep)) }
        #expect(throws: BuiltInCalculator.Failure.tooDeep) { try calculate(String(repeating: "-", count: 900) + "1") }
        #expect(throws: BuiltInCalculator.Failure.tooDeep) { try calculate(String(repeating: "2^", count: 400) + "2") }
        #expect(throws: BuiltInCalculator.Failure.tooDeep) { try calculate(String(repeating: "sin(", count: 150) + "1" + String(repeating: ")", count: 150)) }
    }

    @Test func nestingUnderTheCapWorks() throws {
        let fine = 60
        #expect(try calculate(String(repeating: "(", count: fine) + "1" + String(repeating: ")", count: fine)) == 1)
    }

    @Test(arguments: [
        (0.0, "0"), (-0.0, "0"), (42, "42"), (-7, "-7"), (2.5, "2.5"), (0.30000000000000004, "0.3"), (1e14, "100000000000000"),
        (999_999_999_999_999, "999999999999999"), (1e15, "1e+15"), (1.0 / 3, "0.333333333333333"), (1e-7, "1e-07"),
    ])
    func formats(_ value: Double, _ text: String) {
        #expect(BuiltInCalculator.format(value) == text)
    }
}
