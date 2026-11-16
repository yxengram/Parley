import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Skills on the app side, with tools/mock_server.py as the model. Every skill is written into the
// fixture's own skills folder (Fixture.skillsRoot); nothing reads the user's.

private func ask(_ args: String) -> String {
    "call tool=builtin__activate_skill args=\(args)"
}

private func sentRequest(_ fx: Fixture) async throws -> [String: Any] {
    let url = URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + "/mock/last-messages")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private func sentTools(_ fx: Fixture) async throws -> [String] {
    let tools = try await sentRequest(fx)["tools"] as? [[String: Any]] ?? []
    return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
}

@MainActor
private func addSkill(_ fx: Fixture, name: String = "release-notes", description: String = "Writes release notes. Use for a changelog.") throws {
    let dir = fx.skillsRoot.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("templates"), withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n\nGroup the changes into New and Fixed.\n"
        .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "## New\n".write(to: dir.appendingPathComponent("templates/notes.md"), atomically: true, encoding: .utf8)
    fx.state.reloadSkills()
}

@MainActor
private func reply(_ session: ConversationSession) throws -> Message {
    try #require(session.conversation.messages.last)
}

private func firstCall(_ message: Message) throws -> ToolCallRecord {
    try #require(message.toolRounds?.first?.calls.first)
}

@Suite @MainActor struct SkillSettingsTests {
    private func withApp(_ body: (Fixture) async throws -> Void) async throws {
        let fx = try Fixture(baseURL: "http://127.0.0.1:9/v1", defaultModel: "m", mcp: FakeToolHost())
        defer { fx.cleanup() }
        try await body(fx)
    }

    @Test func noSkillsMeansNothingIsOffered() async throws {
        try await withApp { fx in
            #expect(fx.state.skills.isEmpty && fx.state.skillProblems.isEmpty)
            #expect(fx.state.enabledServers(for: ConversationSettings()).isEmpty)
            #expect(!fx.state.offersTools)
            #expect(!FileManager.default.fileExists(atPath: fx.skillsRoot.path), "looking creates nothing")
            #expect(AppState(settings: fx.settings).skills.isEmpty, "no folder given: none, and not the user's")
        }
    }

    @Test func aSkillIsOnOnceAddedAndCanBeSwitchedOff() async throws {
        try await withApp { fx in
            try addSkill(fx)
            let skill = try #require(fx.state.skills.first)
            #expect(fx.state.isSkillOn(skill) && fx.state.offersTools)
            let servers = fx.state.enabledServers(for: ConversationSettings())
            #expect(servers.map(\.id) == [BuiltInTools.serverID])
            #expect(fx.state.toolDefinitionTokens(for: ConversationSettings()) > 0)

            fx.state.setSkill(skill, on: false)
            #expect(fx.settings.disabledSkills == ["release-notes"])
            #expect(fx.state.enabledServers(for: ConversationSettings()).isEmpty)
            #expect(!fx.state.offersTools)
            #expect(AppSettings(defaults: fx.defaults).disabledSkills == ["release-notes"], "kept across launches")
            fx.state.setSkill(skill, on: true)
            #expect(fx.settings.disabledSkills.isEmpty)
        }
    }

    @Test func theConversationCanOptOutAndTheFileSaysSoOnlyThen() async throws {
        try await withApp { fx in
            try addSkill(fx)
            var settings = ConversationSettings()
            #expect(!String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("skillsOff"))
            settings.usesSkills = false
            #expect(settings.skillsOff == true)
            #expect(fx.state.enabledServers(for: settings).isEmpty)
            settings.usesSkills = true
            #expect(settings.skillsOff == nil)

            // Built-in tools off, skills on: only activate_skill.
            fx.settings.builtInTools = ["current_time"]
            settings.usesBuiltInTools = false
            let config = try #require(fx.state.enabledServers(for: settings).first)
            #expect(BuiltInTools.bindings(for: config, skills: fx.state.builtInToolSettings.skills).map(\.exposedName)
                == ["builtin__activate_skill"])
        }
    }

    @Test func importingSwitchesTheSkillOn() async throws {
        try await withApp { fx in
            let source = fx.root.appendingPathComponent("Downloads/new-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: new-skill\ndescription: New.\n---\nBody".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            fx.settings.disabledSkills = ["new-skill"]
            let staged = try await fx.state.stageSkills(from: source)
            #expect(staged.conflicts.isEmpty)
            #expect(try await fx.state.installSkills(staged) == ["new-skill"])
            #expect(fx.state.skills.map(\.name) == ["new-skill"])
            #expect(fx.state.enabledSkills.map(\.name) == ["new-skill"], "an import is a request to use it")
        }
    }

    @Test func aRowNamesTheSkill() {
        var call = ToolCallRecord(id: "c", name: "builtin__activate_skill", arguments: #"{"name":"release-notes"}"#)
        call.serverID = BuiltInTools.serverID
        call.serverName = "Parley"
        call.toolName = BuiltInTools.skillToolName
        #expect(ToolDisplay.title(call) == "Parley › activate_skill: release-notes")
        call.arguments = #"{"name":"release-notes","file":"templates/notes.md"}"#
        #expect(ToolDisplay.title(call) == "Parley › activate_skill: release-notes / templates/notes.md")
    }
}

@Suite @MainActor struct SkillLoopTests {
    @Test func theModelLoadsASkillWithoutACard() async throws {
        try await withFixture(model: "mock-tools", mcp: FakeToolHost()) { fx in
            try addSkill(fx)
            let session = try await fx.create()
            try await fx.send(ask(#"{"name":"release-notes"}"#), in: session)
            let message = try reply(session)
            let call = try firstCall(message)
            #expect(message.error == nil && message.isComplete)
            #expect(call.toolName == BuiltInTools.skillToolName && call.result?.callStatus == .completed)
            #expect(call.result?.text.contains("Group the changes into New and Fixed.") == true)
            #expect(call.result?.text.contains("<file>templates/notes.md</file>") == true)
            #expect(call.result?.text.contains(fx.root.path) == false)
            #expect(try await sentTools(fx) == ["builtin__activate_skill"])
            let tools = try await sentRequest(fx)["tools"] as? [[String: Any]] ?? []
            let description = (tools.first?["function"] as? [String: Any])?["description"] as? String ?? ""
            #expect(description.contains("- release-notes: Writes release notes. Use for a changelog."))
        }
    }

    @Test func aConversationThatOptedOutGetsNoSkillsAndAForkKeepsThat() async throws {
        try await withFixture(model: "mock-plain", mcp: FakeToolHost()) { fx in
            try addSkill(fx)
            let session = try await fx.create()
            session.conversation.settings.usesSkills = false
            try await fx.send("hello", in: session)
            #expect(try await sentTools(fx).isEmpty)
            #expect(try readPlain(session.fileURL).settings.skillsOff == true)
            fx.state.fork(session, through: 0)
            let forked = try #require(fx.state.session(for: fx.state.selection))
            #expect(!forked.conversation.settings.usesSkills)
        }
    }

    @Test func inReActEveryLoadAsks() async throws {
        try await withFixture(model: "mock-react", mcp: FakeToolHost()) { fx in
            try addSkill(fx)
            let session = try await fx.create()
            session.conversation.settings.toolMode = ConversationSettings.toolModeReAct
            session.send(text: ask(#"{"name":"release-notes"}"#), attachments: [], settings: fx.settings)
            try #require(await waitUntil { session.pendingApproval != nil }, "no approval card")
            let approval = try #require(session.pendingApproval)
            #expect(approval.readFromText && !approval.offersAlwaysAllow)
            #expect(approval.isBuiltIn)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            #expect(try firstCall(try reply(session)).result?.callStatus == .completed)
        }
    }

    @Test func aSkillSwitchedOffDuringAReplyIsNotRead() async throws {
        try await withFixture(model: "mock-react", mcp: FakeToolHost()) { fx in
            try addSkill(fx)
            let session = try await fx.create()
            session.conversation.settings.toolMode = ConversationSettings.toolModeReAct
            session.send(text: ask(#"{"name":"release-notes"}"#), attachments: [], settings: fx.settings)
            try #require(await waitUntil { session.pendingApproval != nil }, "no approval card")
            let skill = try #require(fx.state.skills.first)
            fx.state.setSkill(skill, on: false)
            session.answerApproval(.allowOnce)
            try await fx.waitForReply(session)
            let result = try firstCall(try reply(session)).result
            #expect(result?.callStatus == .notCalled)
            #expect(result?.text.contains("Group the changes") == false)
        }
    }
}
