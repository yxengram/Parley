import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// The built-in tools on the app side: the settings, what a conversation is offered, and the whole
// reply loop with tools/mock_server.py as the model. The files are real ones in the fixture's temp
// folder. Nothing here resolves a name or leaves this Mac: a fetch is either denied at its card, or
// allowed for a loopback address, which the tool refuses without connecting.
// BuiltInOffGoldenTests holds the bytes of a conversation with every tool off.

private let allNames = BuiltInTools.Tool.allCases.map(\.rawValue)

private func ask(_ tool: String, args: String = "{}") -> String {
    "call tool=builtin__\(tool) args=\(args)"
}

private func mockJSON(_ fx: Fixture, _ path: String) async throws -> [String: Any] {
    let url = URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + path)!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private func sentTools(_ fx: Fixture) async throws -> [String] {
    let sent = try await mockJSON(fx, "/mock/last-messages")
    let tools = sent["tools"] as? [[String: Any]] ?? []
    return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
}

private func sentMessages(_ fx: Fixture) async throws -> [[String: Any]] {
    try await mockJSON(fx, "/mock/last-messages")["messages"] as? [[String: Any]] ?? []
}

/// One shared folder with a file and a hidden file in it.
@MainActor
private func shareFolder(_ fx: Fixture) throws -> URL {
    let folder = fx.root.appendingPathComponent("Shared-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "the file's text".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    fx.settings.builtInFolderPath = folder.path
    return folder
}

@MainActor
private func addServer(_ fx: Fixture) throws -> MCPServerConfig {
    let config = MCPServerConfig(name: "Mock", command: "/usr/bin/true", useInNewChats: true)
    return try fx.state.saveServer(config, secrets: MCPServerSecrets(args: ["--fake"]))
}

/// A conversation with no MCP server and the given tools on.
@MainActor
private func withBuiltIns(
    _ tools: [BuiltInTools.Tool],
    model: String = "mock-tools",
    flavor: String? = nil,
    react: Bool = false,
    _ body: (Fixture, ConversationSession, FakeToolHost) async throws -> Void
) async throws {
    let host = FakeToolHost()
    try await withFixture(model: model, flavor: flavor, mcp: host) { fx in
        if tools.contains(where: \.needsFolder) { _ = try shareFolder(fx) }
        fx.settings.builtInTools = tools.map(\.rawValue)
        let session = try await fx.create()
        if react { session.conversation.settings.toolMode = ConversationSettings.toolModeReAct }
        try await body(fx, session, host)
    }
}

@MainActor
private func start(_ text: String, _ fx: Fixture, _ session: ConversationSession) {
    session.send(text: text, attachments: [], settings: fx.settings)
}

@MainActor
private func waitForApproval(_ session: ConversationSession) async throws -> PendingToolApproval {
    try #require(await waitUntil { session.pendingApproval != nil }, "no approval card")
    return try #require(session.pendingApproval)
}

@MainActor
private func reply(_ session: ConversationSession) throws -> Message {
    try #require(session.conversation.messages.last)
}

/// Every phase seen until the reply ends.
@MainActor
private func phasesUntilDone(_ session: ConversationSession) async -> [ConversationSession.ReplyPhase] {
    var phases: [ConversationSession.ReplyPhase] = []
    while session.isStreaming {
        if let phase = session.replyPhase { phases.append(phase) }
        await Task.yield()
    }
    return phases
}

private func firstCall(_ message: Message) throws -> ToolCallRecord {
    try #require(message.toolRounds?.first?.calls.first)
}

// MARK: - Settings and what a conversation is offered

@Suite @MainActor struct BuiltInSettingsTests {
    /// No server behind it: nothing here sends.
    private func withApp(_ body: (Fixture, FakeToolHost) async throws -> Void) async throws {
        let host = FakeToolHost()
        let fx = try Fixture(baseURL: "http://127.0.0.1:9/v1", defaultModel: "m", mcp: host)
        defer { fx.cleanup() }
        try await body(fx, host)
    }

    @Test func everythingIsOffByDefaultAndNothingIsStored() async throws {
        try await withApp { fx, _ in
            #expect(fx.settings.builtInTools.isEmpty)
            #expect(fx.settings.builtInFolderPath == nil)
            #expect(fx.settings.builtInToolSettings.effectiveTools.isEmpty)
            #expect(fx.settings.builtInToolSettings == .off)
            #expect(!fx.settings.offersTools)
            #expect(fx.state.enabledServers(for: ConversationSettings()) == [])
            #expect(fx.state.toolDefinitionTokens(for: ConversationSettings()) == 0)
            #expect(fx.defaults.object(forKey: "builtInTools") == nil)
            #expect(fx.defaults.object(forKey: "builtInFolderPath") == nil)
        }
    }

    @Test func theChoiceSurvivesARestartAndANameFromALaterVersionIsKept() async throws {
        try await withApp { fx, _ in
            fx.defaults.set(["web_search", "current_time"], forKey: "builtInTools")
            fx.defaults.set("/some/folder", forKey: "builtInFolderPath")
            let settings = AppSettings(defaults: fx.defaults)
            #expect(settings.builtInToolSettings.effectiveTools == [.currentTime])
            #expect(settings.builtInFolderPath == "/some/folder")

            settings.setBuiltInTool(.calculate, on: true)
            settings.setBuiltInTool(.currentTime, on: false)
            #expect(AppSettings(defaults: fx.defaults).builtInTools == ["web_search", "calculate"])
        }
    }

    @Test func aWrongStoredTypeIsNoTools() async throws {
        try await withApp { fx, _ in
            fx.defaults.set("current_time", forKey: "builtInTools")
            fx.defaults.set(7, forKey: "builtInFolderPath")
            let settings = AppSettings(defaults: fx.defaults)
            #expect(settings.builtInToolSettings.effectiveTools.isEmpty)
        }
    }

    @Test func theFileToolsNeedTheFolder() async throws {
        try await withApp { fx, _ in
            fx.settings.builtInTools = ["list_files", "read_file"]
            #expect(fx.state.enabledServers(for: ConversationSettings()) == [])
            #expect(!fx.settings.offersTools)

            fx.settings.builtInFolderPath = "/some/folder"
            let servers = fx.state.enabledServers(for: ConversationSettings())
            let server = try #require(servers.first)
            #expect(servers.count == 1)
            #expect(server.id == BuiltInTools.serverID && server.kind == MCPServerConfig.kindBuiltIn)
            #expect(Set(server.disabledTools) == ["current_time", "calculate", "fetch_url", "browse_url"])
            #expect(fx.settings.offersTools)
        }
    }

    @Test func clearingTheFolderTurnsTheFileToolsOffForGood() async throws {
        try await withApp { fx, _ in
            fx.settings.builtInFolderPath = "/some/folder"
            fx.settings.builtInTools = allNames + ["web_search"]
            fx.settings.clearBuiltInFolder()
            #expect(fx.settings.builtInFolderPath == nil)
            #expect(fx.defaults.object(forKey: "builtInFolderPath") == nil)
            #expect(fx.settings.builtInTools == ["current_time", "calculate", "fetch_url", "browse_url", "web_search"])

            // A new folder shares nothing until a file tool is turned on again.
            fx.settings.builtInFolderPath = "/another/folder"
            #expect(fx.settings.builtInToolSettings.effectiveTools == [.currentTime, .calculate, .fetchURL, .browseURL])
        }
    }

    @Test func builtInsComeAfterTheServersAndAConversationCanOptOut() async throws {
        try await withApp { fx, _ in
            let server = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            var conversation = ConversationSettings()
            conversation.mcpServerIDs = [server.id]
            #expect(fx.state.enabledServers(for: conversation).map(\.id) == [server.id, BuiltInTools.serverID])

            conversation.usesBuiltInTools = false
            #expect(fx.state.enabledServers(for: conversation).map(\.id) == [server.id])
            #expect(fx.state.mcpServer(BuiltInTools.serverID) == nil, "never a stored server")
        }
    }

    /// Correction 2's second half: the host a session talks to, with no real server listed.
    @Test func withoutARealServerTheRealHostHearsNothing() async throws {
        try await withApp { fx, host in
            let router = fx.state.toolHost
            _ = await router.catalog(for: [])
            fx.settings.builtInTools = ["current_time"]
            let config = try #require(BuiltInTools.serverConfig(fx.settings.builtInToolSettings))
            let listed = await router.catalog(for: [config])
            #expect(listed.bindings.map(\.exposedName) == ["builtin__current_time"])
            let binding = try #require(listed.bindings.first)
            let result = await router.call(binding, arguments: [:], timeout: 5, maxCharacters: 2000)
            #expect(result.callStatus == .completed)
            _ = await router.connect(config)
            await router.stop(serverID: BuiltInTools.serverID)
            await router.forget(serverID: BuiltInTools.serverID)
            await router.clearLogs(serverIDs: [BuiltInTools.serverID])
            #expect(host.catalogCount == 0)
            #expect(host.calls.isEmpty)
            #expect(host.forgottenServers.isEmpty)
            #expect(host.clearedLogs.isEmpty)
        }
    }

    @Test func onlyTheHarmlessToolsRunWithoutAsking() async throws {
        try await withApp { fx, _ in
            fx.settings.builtInFolderPath = "/some/folder"
            fx.settings.builtInTools = allNames
            let config = try #require(BuiltInTools.serverConfig(fx.settings.builtInToolSettings))
            let allowance = Dictionary(uniqueKeysWithValues: BuiltInTools.bindings(for: config).map { ($0.tool.name, fx.state.toolAllowance($0)) })
            #expect(allowance["current_time"] == .always)
            #expect(allowance["calculate"] == .always)
            #expect(allowance["list_files"] == .ask)
            #expect(allowance["read_file"] == .ask)
            #expect(allowance["fetch_url"] == .ask)
            #expect(allowance["browse_url"] == .ask)
            #expect(allowance.count == 6)

            // Nothing can be stored for them, and nothing is.
            let before = fx.settings.mcpServers
            for binding in BuiltInTools.bindings(for: config) { fx.state.setAlwaysAllowed(binding) }
            #expect(fx.settings.mcpServers == before)
            #expect(BuiltInTools.bindings(for: config).allSatisfy { fx.state.toolAllowance($0) != .changed })
        }
    }

    @Test func theDefinitionsCountInTheContextOnlyWhileOffered() async throws {
        try await withApp { fx, _ in
            fx.settings.builtInTools = ["current_time"]
            let one = fx.state.toolDefinitionTokens(for: ConversationSettings())
            #expect(one > 0)
            fx.settings.builtInTools = ["current_time", "calculate"]
            #expect(fx.state.toolDefinitionTokens(for: ConversationSettings()) > one)

            var optedOut = ConversationSettings()
            optedOut.usesBuiltInTools = false
            #expect(fx.state.toolDefinitionTokens(for: optedOut) == 0)
        }
    }

    @Test func theCheckboxStoresNothingUnlessTheUserOptedOut() throws {
        var settings = ConversationSettings()
        #expect(settings.usesBuiltInTools)
        let plain = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!plain.contains("builtInToolsOff"))

        settings.usesBuiltInTools = false
        #expect(settings.builtInToolsOff == true)
        #expect(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains(#""builtInToolsOff":true"#))

        settings.usesBuiltInTools = true
        #expect(settings.builtInToolsOff == nil)
        #expect(!String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("builtInToolsOff"))
    }

    /// What the user is told to read must be what it looks like.
    @Test(arguments: [
        "https://ex%D0%B0mple.org/", "https://%D7%90.org/", "https://ex\u{0430}mple.org/", "https://\u{05D0}.org/",
        "https://a%20b.org/", "https://\u{4F8B}\u{5B50}.com/", "https://example.org/",
    ])
    func theCardsHostIsPlainASCII(address: String) {
        let detail = BuiltInTools.approvalDetail(toolName: "fetch_url", arguments: ["url": .string(address)], folderPath: nil)
        #expect(detail.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }, "\(detail)")
        #expect(!detail.contains("%"))
    }

    @Test func theCardOffersAlwaysAllowOnlyForAStructuredCallToARealServer() {
        func card(fromText: Bool = false, everyTime: Bool = false, builtIn: Bool = false) -> PendingToolApproval {
            PendingToolApproval(id: "a", serverName: "s", serverDetail: "", toolName: "t", description: nil, parameters: "{}",
                                arguments: "{}", definitionChanged: false, readFromText: fromText, asksEveryTime: everyTime, isBuiltIn: builtIn)
        }
        #expect(card().offersAlwaysAllow)
        #expect(!card(fromText: true).offersAlwaysAllow)
        #expect(!card(everyTime: true).offersAlwaysAllow)
        #expect(card().definitionLabel == "Definition from the server")
        #expect(card(builtIn: true).definitionLabel == "Definition from Parley")
    }

    @Test func theSettingsRowsSayWhatAsks() {
        for tool in BuiltInTools.Tool.allCases {
            let text = BuiltInToolsSettingsView.explanation(tool)
            #expect(text.contains(tool.asksEveryTime ? "Asks every time" : "Runs without asking"), "\(tool)")
        }
    }

    @Test func aRowReadsTheRecordAlone() async throws {
        try await withApp { fx, _ in
            // What a replayed row reads: the record alone.
            let call = ToolCallRecord(id: "a", name: "builtin__read_file", arguments: "{}", serverID: BuiltInTools.serverID,
                                      serverName: BuiltInTools.serverName, toolName: "read_file")
            #expect(ToolDisplay.title(call) == "Parley › read_file")
        }
    }
}

// MARK: - The reply loop

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
@MainActor
struct BuiltInLoopTests {
    // MARK: Native calls

    @Test func withEverythingOffARequestCarriesNoTools() async throws {
        try await withBuiltIns([], model: "mock-plain") { fx, session, host in
            try await fx.send("hello", in: session)
            #expect(try reply(session).content == echo("hello"))
            #expect(try await sentTools(fx).isEmpty)
            #expect(try reply(session).toolDefinitionTokens == nil)
            #expect(host.catalogCount == 0)
        }
    }

    @Test func currentTimeRunsWithoutACard() async throws {
        try await withBuiltIns([.currentTime]) { fx, session, host in
            try await fx.send(ask("current_time"), in: session)
            let message = try reply(session)
            let call = try firstCall(message)
            #expect(message.error == nil && message.isComplete)
            #expect(call.serverID == BuiltInTools.serverID && call.serverName == "Parley" && call.toolName == "current_time")
            #expect(call.result?.callStatus == .completed)
            #expect(call.result?.text.contains(TimeZone.current.identifier) == true)
            #expect(message.toolDefinitionTokens ?? 0 > 0)
            #expect(try await sentTools(fx) == ["builtin__current_time"])
            #expect(host.catalogCount == 0, "nothing else is asked for")
            #expect(host.calls.isEmpty)
        }
    }

    @Test func calculateRunsWithoutACardAndItsErrorReachesTheModel() async throws {
        try await withBuiltIns([.calculate]) { fx, session, _ in
            try await fx.send(ask("calculate", args: #"{"expression":"(2+3)*4"}"#), in: session)
            #expect(try firstCall(try reply(session)).result?.text == "20")

            try await fx.send(ask("calculate", args: #"{"expression":"1/0"}"#), in: session)
            let failed = try firstCall(try reply(session))
            #expect(failed.result?.callStatus == .toolError)
        }
    }

    @Test func listFilesAsksEveryTimeAndShowsTheFolderOnlyOnTheCard() async throws {
        try await withBuiltIns([.listFiles]) { fx, session, _ in
            start(ask("list_files"), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.isBuiltIn && approval.asksEveryTime && !approval.offersAlwaysAllow)
            #expect(approval.serverName == "Parley")
            #expect(approval.serverDetail == "Built-in tool, in folder Shared-folder")
            #expect(approval.definitionLabel == "Definition from Parley")
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)

            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.callStatus == .completed)
            #expect(result.text.contains("notes.txt"))
            #expect(!result.text.contains(".env"))
            for leak in ["Shared-folder", fx.root.path, NSUserName()] {
                #expect(!result.text.contains(leak))
            }
            #expect(fx.settings.mcpServers.isEmpty)

            // Allowed once means once.
            start(ask("list_files"), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .denied)
        }
    }

    @Test func readFileAsksAndReturnsTheText() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.toolName == "read_file" && approval.arguments.contains("notes.txt"))
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.text == "the file's text")

            start(ask("read_file", args: #"{"path":".env"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let hidden = try #require(try firstCall(try reply(session)).result)
            #expect(hidden.callStatus == .toolError)
            #expect(!hidden.text.contains("secret"))
        }
    }

    @Test func aDeniedReadReadsNothing() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            let call = try firstCall(try reply(session))
            #expect(call.result?.callStatus == .denied)
            #expect(call.result?.text == ToolResultText.denied)
            #expect(call.startedAt == nil)
        }
    }

    /// Denied: the name in it is never looked up.
    @Test func theFetchCardNamesTheHostAndWholeAddress() async throws {
        try await withBuiltIns([.fetchURL]) { fx, session, _ in
            start(ask("fetch_url", args: #"{"url":"https://example.org/a?b=c"}"#), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.serverDetail == "Built-in tool, contacts example.org")
            #expect(approval.arguments.contains("https://example.org/a?b=c"))
            #expect(approval.asksEveryTime && !approval.offersAlwaysAllow)
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .denied)
        }
    }

    /// The mock is on loopback, and the default floor refuses that without connecting.
    @Test func allowedFetchesOfThisMacAreStillRefused() async throws {
        try await withBuiltIns([.fetchURL]) { fx, session, _ in
            let target = fx.provider.baseURL + "/models"
            start(ask("fetch_url", args: #"{"url":"\#(target)"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.callStatus == .toolError)
            #expect(!result.text.contains("mock-tools"), "no answer came back")
        }
    }

    /// Denied: nothing is opened, and the name is never looked up.
    @Test func theBrowseCardNamesTheHostAndSaysOtherSitesMayBeContacted() async throws {
        try await withBuiltIns([.browseURL]) { fx, session, _ in
            fx.settings.builtInBrowseOtherSites = true
            start(ask("browse_url", args: #"{"url":"https://example.org/a?b=c","links":true}"#), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.serverDetail == "Built-in tool, opens example.org in a private browser; its scripts may contact other public sites")
            #expect(approval.arguments.contains("https://example.org/a?b=c"))
            #expect(approval.asksEveryTime && !approval.offersAlwaysAllow)
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .denied)
            #expect(fx.state.pageLoader.openPages == 0)
        }
    }

    @Test func otherSitesAreOffByDefaultAndTheCardSaysSo() async throws {
        try await withBuiltIns([.browseURL]) { fx, session, _ in
            #expect(!fx.settings.builtInBrowseOtherSites)
            #expect(fx.defaults.object(forKey: "builtInBrowseOtherSites") == nil)
            #expect(!fx.settings.builtInToolSettings.browseOtherSites)
            start(ask("browse_url", args: #"{"url":"https://example.org/"}"#), fx, session)
            #expect(try await waitForApproval(session).serverDetail
                == "Built-in tool, opens example.org in a private browser, loading only from that site")
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            fx.settings.builtInBrowseOtherSites = true
            #expect(fx.defaults.bool(forKey: "builtInBrowseOtherSites"))
            #expect(fx.settings.builtInToolSettings.browseOtherSites)
        }
    }

    /// An Allow means the switch as the card showed it, as it does for the folder.
    @Test func turningOtherSitesOnDuringTheCardRunsNothing() async throws {
        try await withBuiltIns([.browseURL]) { fx, session, _ in
            start(ask("browse_url", args: #"{"url":"https://example.org/"}"#), fx, session)
            #expect(try await waitForApproval(session).serverDetail.hasSuffix("loading only from that site"))
            fx.settings.builtInBrowseOtherSites = true
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.text == ToolResultText.turnedOff)
            #expect(result.callStatus == .notCalled)
            #expect(fx.state.pageLoader.openPages == 0)
        }
    }

    /// The app's own router has the WebKit loader (the tool is not "not available"), and its floor
    /// refuses the loopback mock before any web view exists.
    @Test func allowedBrowsesOfThisMacAreStillRefused() async throws {
        try await withBuiltIns([.browseURL]) { fx, session, _ in
            let target = fx.provider.baseURL + "/models"
            start(ask("browse_url", args: #"{"url":"\#(target)"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.callStatus == .toolError)
            #expect(result.text.contains("was refused: only public internet addresses can be opened"))
            #expect(!result.text.contains("mock-tools"), "no answer came back")
            #expect(fx.state.pageLoader.openPages == 0)
        }
    }

    // MARK: ReAct

    @Test(arguments: [
        (BuiltInTools.Tool.currentTime, "{}"),
        (BuiltInTools.Tool.calculate, #"{"expression":"6*7"}"#),
        (BuiltInTools.Tool.listFiles, "{}"),
        (BuiltInTools.Tool.readFile, #"{"path":"notes.txt"}"#),
    ])
    func everyReActCallAsks(tool: BuiltInTools.Tool, args: String) async throws {
        try await withBuiltIns([tool], model: "mock-react", react: true) { fx, session, _ in
            start(ask(tool.rawValue, args: args), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.readFromText && !approval.offersAlwaysAllow)
            #expect(approval.isBuiltIn)
            #expect(try await sentTools(fx).isEmpty, "no `tools` in ReAct")
            let system = try await sentMessages(fx).first?["content"] as? String
            #expect(system?.contains("Tool: builtin__\(tool.rawValue)") == true)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .completed)
            #expect(try reply(session).error == nil)
        }
    }

    @Test func aFetchReadFromTextAsksAndCanBeDenied() async throws {
        try await withBuiltIns([.fetchURL], model: "mock-react", react: true) { fx, session, _ in
            start(ask("fetch_url", args: #"{"url":"https://example.org/"}"#), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.readFromText && approval.asksEveryTime)
            #expect(approval.serverDetail == "Built-in tool, contacts example.org")
            session.answerApproval(.deny)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .denied)
        }
    }

    // MARK: Switched off in the middle of a reply

    @Test func aToolTurnedOffDuringTheCardDoesNotRun() async throws {
        try await withBuiltIns([.readFile, .currentTime]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            fx.settings.setBuiltInTool(.readFile, on: false)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.callStatus == .notCalled)
            #expect(result.text == ToolResultText.turnedOff)
        }
    }

    @Test func clearingTheFolderDuringTheCardRunsNothing() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            fx.settings.clearBuiltInFolder()
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.text == ToolResultText.turnedOff)
        }
    }

    private func otherFolder(_ fx: Fixture) throws -> URL {
        let other = fx.root.appendingPathComponent("Personal", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "personal text".write(to: other.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return other
    }

    @Test func choosingAnotherFolderDuringTheCardRunsNothing() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            #expect(try await waitForApproval(session).serverDetail == "Built-in tool, in folder Shared-folder: notes.txt")
            fx.settings.builtInFolderPath = try otherFolder(fx).path
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.text == ToolResultText.turnedOff)
            #expect(result.callStatus == .notCalled)
        }
    }

    /// The folder moves at the runner's own read of Settings, after the check above has passed.
    @Test func textFromAFolderChosenAsTheCallStartsGoesNowhere() async throws {
        try await withBuiltIns([.readFile]) { fx, session, host in
            let other = try otherFolder(fx)
            let settings = fx.settings
            session.tools?.host = BuiltInToolRouter(wrapping: host, settings: {
                await MainActor.run {
                    settings.builtInFolderPath = other.path
                    return settings.builtInToolSettings
                }
            })
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try #require(try firstCall(try reply(session)).result)
            #expect(result.text == ToolResultText.turnedOff)
            #expect(result.callStatus == .notCalled)
            let flat = try await sentMessages(fx).compactMap { $0["content"] as? String }.joined(separator: "\n")
            #expect(!flat.contains("personal text"))
        }
    }

    /// `path` is what is read, and it sorts after anything the model puts before it.
    @Test func theCardNamesTheRealPathAboveAnyDecoy() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            let padding = String(repeating: "x", count: 3000)
            start(ask("read_file", args: #"{"file":"docs/README.md","padding":"\#(padding)","path":"notes.txt"}"#), fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.serverDetail == "Built-in tool, in folder Shared-folder: notes.txt")
            #expect(approval.arguments.hasPrefix("{\n  \"file\" : \"docs/README.md\""))
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.text == "the file's text")
        }
    }

    @Test func optingOutDuringTheCardRunsNothing() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.conversation.settings.usesBuiltInTools = false
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.text == ToolResultText.turnedOff)
        }
    }

    @Test func stopDuringTheCardLeavesTheCallResolvedAndNothingRead() async throws {
        try await withBuiltIns([.readFile]) { fx, session, _ in
            start(ask("read_file", args: #"{"path":"notes.txt"}"#), fx, session)
            _ = try await waitForApproval(session)
            session.stop()
            #expect(session.pendingApproval == nil)
            let call = try firstCall(try reply(session))
            #expect(call.result?.callStatus == .cancelled)
            #expect(call.result?.text == ToolResultText.notRun)
        }
    }

    // MARK: The opt-out

    @Test func aConversationThatOptedOutSendsNoBuiltIns() async throws {
        try await withBuiltIns([.currentTime], model: "mock-plain") { fx, session, _ in
            session.conversation.settings.usesBuiltInTools = false
            try await fx.send("hello", in: session)
            #expect(try await sentTools(fx).isEmpty)
            #expect(try readPlain(session.fileURL).settings.builtInToolsOff == true)

            session.conversation.settings.usesBuiltInTools = true
            try await fx.send("again", in: session)
            #expect(try await sentTools(fx) == ["builtin__current_time"])
        }
    }

    @Test func aForkKeepsTheOptOut() async throws {
        try await withBuiltIns([.currentTime], model: "mock-plain") { fx, session, _ in
            session.conversation.settings.usesBuiltInTools = false
            try await fx.send("hello", in: session)
            fx.state.fork(session, through: 0)
            let forked = try #require(fx.state.session(for: fx.state.selection))
            #expect(forked.id != session.id)
            #expect(!forked.conversation.settings.usesBuiltInTools)
            #expect(fx.state.enabledServers(for: forked.conversation.settings).isEmpty)
        }
    }

    // MARK: Beside a real server

    @Test func aRealServerAndTheBuiltInsMerge() async throws {
        let host = FakeToolHost()
        try await withFixture(model: "mock-tools", mcp: host) { fx in
            _ = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            let session = try await fx.create()

            try await fx.send(ask("current_time"), in: session)
            #expect(Set(try await sentTools(fx)) == ["mock__echo", "mock__add", "builtin__current_time"])
            #expect(host.catalogCount == 1)
            #expect(host.calls.isEmpty, "a built-in call never reaches the real host")

            start("call tool=mock__echo args={\"text\":\"hi\"}", fx, session)
            let approval = try await waitForApproval(session)
            #expect(approval.offersAlwaysAllow && !approval.isBuiltIn)
            #expect(approval.definitionLabel == "Definition from the server")
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(host.calls.map(\.tool) == ["echo"])
        }
    }

    @Test func onlyRealServersAreStarted() async throws {
        let host = FakeToolHost()
        host.holdCatalog()
        try await withFixture(model: "mock-tools", mcp: host) { fx in
            _ = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            let session = try await fx.create()
            start("hello", fx, session)
            try #require(await waitUntil { session.replyPhase == .connecting(["Mock"]) }, "Parley is not a server that starts")
            session.stop()
        }
    }

    @Test func aRealServerStillGetsItsNotesAndItsWait() async throws {
        let host = FakeToolHost()
        try await withFixture(model: "mock-tools-refuse-ollama", mcp: host) { fx in
            _ = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            #expect(try reply(session).toolNotes?.map(\.kind) == [ToolNote.toolsNotAccepted])
            try await fx.send("again", in: session)
            #expect(try reply(session).toolNotes?.map(\.kind) == [ToolNote.toolsNotAccepted])
        }

        try await withFixture(model: "strata-qwen", flavor: "strata-runtime", mcp: host) { fx in
            _ = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            let session = try await fx.create()
            var waited = false
            let wait = session.awaitServerInfo
            session.awaitServerInfo = { provider, model, forBudget in
                await MainActor.run { waited = true }
                return await wait?(provider, model, forBudget)
            }
            try await fx.send("hello", in: session)
            #expect(waited)
            #expect(try reply(session).toolNotes?.map(\.kind) == [ToolNote.toolsNotOffered])
        }
    }

    // MARK: A conversation with no MCP server stays a plain chat

    @Test func aStrataRuntimeModelGetsNoNoteAndNoTools() async throws {
        try await withBuiltIns([.currentTime], model: "strata-qwen", flavor: "strata-runtime") { fx, session, host in
            let info = await fx.state.awaitServerInfo(provider: fx.provider, model: "strata-qwen")
            #expect(info?.ignoresTools == true)
            #expect(fx.state.toolDefinitionTokens(for: session.conversation.settings) == 0)
            try await fx.send("hello", in: session)
            let message = try reply(session)
            #expect(message.error == nil && message.isComplete)
            #expect(message.toolNotes == nil)
            #expect(message.toolDefinitionTokens == nil)
            #expect(try await sentTools(fx).isEmpty)
            #expect(host.catalogCount == 0)
        }
    }

    @Test func aRefusingModelGetsItsOneRetryThenNoToolsAndNoNotes() async throws {
        try await withBuiltIns([.currentTime], model: "mock-tools-refuse-ollama") { fx, session, _ in
            try await fx.send("hello", in: session)
            let first = try reply(session)
            #expect(first.error == nil && first.isComplete)
            #expect(first.toolNotes == nil)
            #expect(first.toolDefinitionTokens == nil)
            #expect(fx.state.toolRefusal(provider: fx.provider, model: "mock-tools-refuse-ollama") != nil)
            #expect(fx.state.toolDefinitionTokens(for: session.conversation.settings) == 0, "they are not sent, so they cost nothing")
            session.conversation.settings.toolMode = ConversationSettings.toolModeReAct
            #expect(fx.state.toolDefinitionTokens(for: session.conversation.settings) > 0, "ReAct does not depend on `tools`")
            session.conversation.settings.toolMode = nil

            try await fx.send("again", in: session)
            let second = try reply(session)
            #expect(second.error == nil && second.toolNotes == nil)
            #expect(try await sentTools(fx).isEmpty)
            // Only what the user sent and got: a retried reply left no trace in the file.
            let disk = try readPlain(session.fileURL)
            #expect(disk.messages.allSatisfy { $0.toolNotes == nil && $0.toolRounds == nil })
        }
    }

    private func counter(_ name: String, _ fx: Fixture) async throws -> Int {
        try await mockJSON(fx, "/mock/requests")[name] as? Int ?? -1
    }

    /// Wording no list has. One toggle earlier this chat worked, so it must go on working.
    @Test func aRefusalInUnknownWordsGetsTheRetryToo() async throws {
        try await withBuiltIns([.currentTime], model: "mock-tools-refuse-unknown") { fx, session, _ in
            try await fx.send("hello", in: session)
            let message = try reply(session)
            #expect(message.error == nil && message.isComplete)
            #expect(message.toolNotes == nil)
            #expect(message.toolDefinitionTokens == nil)
            #expect(try await counter("chat", fx) == 2)
        }
    }

    /// A 500 that goes away without tools proves nothing about the model, so the next send offers
    /// them again.
    @Test func aPassingFaultIsNotRememberedAsARefusal() async throws {
        try await withBuiltIns([.currentTime], model: "mock-tools-refuse-flaky") { fx, session, _ in
            try await fx.send("hello", in: session)
            #expect(try reply(session).error == nil)
            #expect(try reply(session).toolNotes == nil)
            #expect(fx.state.toolRefusal(provider: fx.provider, model: "mock-tools-refuse-flaky") == nil)
            try await fx.send("again", in: session)
            #expect(try reply(session).error == nil)
            #expect(try await counter("chat", fx) == 4)
        }
    }

    /// The other half: with a server the user added, tools are the point, and the error is theirs to see.
    @Test func aRealServerStillSeesARefusalInUnknownWords() async throws {
        let host = FakeToolHost()
        try await withFixture(model: "mock-tools-refuse-unknown", mcp: host) { fx in
            _ = try addServer(fx)
            fx.settings.builtInTools = ["current_time"]
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            #expect(try reply(session).error?.contains("Function Calling") == true)
            #expect(try await counter("chat", fx) == 1)
        }
    }

    @Test func aModelThatFailsAnywayShowsItsFirstError() async throws {
        try await withBuiltIns([.currentTime], model: "mock-tools-refuse-always") { fx, session, _ in
            try await fx.send("hello", in: session)
            #expect(try reply(session).error?.contains("does not support tools") == true)
            #expect(fx.state.toolRefusal(provider: fx.provider, model: "mock-tools-refuse-always") == nil)
        }
    }

    /// Parley's own definitions are all that was sent, so asking again would only fail again.
    @Test(arguments: ["mock-tools-refuse-schema", "mock-tools-refuse-unknown"])
    func aRefusalOfTheBuiltInDefinitionsIsRemembered(model: String) async throws {
        try await withBuiltIns([.currentTime], model: model) { fx, session, _ in
            try await fx.send("hello", in: session)
            #expect(try await counter("chat", fx) == 2)
            #expect(try await counter("requests_with_tools", fx) == 1)
            #expect(fx.state.toolRefusal(provider: fx.provider, model: model) != nil)
            #expect(fx.state.toolDefinitionTokens(for: session.conversation.settings) == 0)

            try await fx.send("again", in: session)
            try await fx.send("and again", in: session)
            #expect(try reply(session).error == nil && reply(session).toolNotes == nil)
            #expect(try await counter("chat", fx) == 4)
            #expect(try await counter("requests_with_tools", fx) == 1)
        }
    }

    /// The memory is per model, and these refusals are about Parley's definitions, not the model.
    @Test(arguments: ["mock-tools-refuse-schema", "mock-tools-refuse-unknown"])
    func thatMemoryLeavesARealServerAlone(model: String) async throws {
        try await withBuiltIns([.currentTime], model: model) { fx, session, _ in
            try await fx.send("hello", in: session)
            let builtInOnly = session.conversation.settings
            let refusal = try #require(fx.state.toolRefusal(provider: fx.provider, model: model))
            #expect(fx.state.refusalApplies(refusal, to: builtInOnly))

            _ = try addServer(fx)
            let second = try await fx.create()
            #expect(!fx.state.refusalApplies(refusal, to: second.conversation.settings))
            try await fx.send("hi", in: second)
            #expect(try await counter("requests_with_tools", fx) == 2, "a chat with a real server still offers its tools")
        }
    }

    @Test func aPlainLackOfSupportStillCoversEveryChat() async throws {
        try await withBuiltIns([.currentTime], model: "mock-tools-refuse-ollama") { fx, session, _ in
            try await fx.send("hello", in: session)
            let refusal = try #require(fx.state.toolRefusal(provider: fx.provider, model: "mock-tools-refuse-ollama"))
            _ = try addServer(fx)
            #expect(fx.state.refusalApplies(refusal, to: try await fx.create().conversation.settings))
        }
    }

    @Test func theFirstSendWaitsForNoProbeAndStartsNothing() async throws {
        try await withBuiltIns([.currentTime], model: "mock-plain") { fx, session, host in
            var waits = 0
            session.awaitServerInfo = { _, _, _ in
                await MainActor.run { waits += 1 }
                return nil
            }
            start("hello", fx, session)
            let phases = await phasesUntilDone(session)
            #expect(waits == 0)
            #expect(phases.allSatisfy { $0 == .generating })
            #expect(host.catalogCount == 0)
            let message = try reply(session)
            #expect(message.error == nil)
            let tools = try await sentTools(fx)
            #expect(tools == ["builtin__current_time"], "tools go out with no kind known")
        }
    }

    /// "None" waits for the kind, as it always did, and for the short time: a built-in is no reason
    /// to wait longer.
    @Test func noThinkingStillWaitsButOnlyAsLongAsWithoutTools() async throws {
        try await withBuiltIns([.currentTime], model: "mock-plain") { fx, session, _ in
            session.conversation.settings.disablesThinking = true
            var asked: [Bool] = []
            session.awaitServerInfo = { _, _, forBudget in
                await MainActor.run { asked.append(forBudget) }
                return nil
            }
            try await fx.send("hello", in: session)
            #expect(asked == [false])
        }
    }

    // MARK: Records

    @Test func aFinishedCallReplaysAfterAToolIsTurnedOffAndARelaunch() async throws {
        try await withBuiltIns([.calculate], model: "mock-tools") { fx, session, host in
            try await fx.send(ask("calculate", args: #"{"expression":"6*7"}"#), in: session)
            let id = session.id
            let call = try firstCall(try reply(session))
            #expect(call.result?.text == "42")
            try #require(session.flushSync() == nil)
            session.close(saving: false)

            fx.settings.builtInTools = []
            let relaunched = AppState(settings: fx.settings, mcp: host, mcpSecrets: fx.mcpSecrets)
            relaunched.reloadLibrary()
            try #require(await waitUntil { relaunched.entries.contains { $0.id == id } })
            let entry = try #require(relaunched.entry(id: id))
            let opened = try #require(await relaunched.loadPlain(entry))
            let row = try firstCall(try reply(opened))
            #expect(ToolDisplay.title(row) == "Parley › calculate")
            #expect(row.replayResult == "42")

            opened.conversation.settings.model = "mock-plain"
            opened.send(text: "what was it?", attachments: [], settings: fx.settings)
            try await fx.waitForReply(opened)
            #expect(try reply(opened).error == nil)
            #expect(try await sentTools(fx).isEmpty)
            let flat = try await sentMessages(fx).compactMap { $0["content"] as? String }.joined(separator: "\n")
            #expect(flat.contains("42"), "the rounds went flattened, as for a server that is gone")
            for session in relaunched.sessions.values { session.close(saving: false) }
        }
    }
}
