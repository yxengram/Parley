import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Context compaction on the app side, with tools/mock_server.py as the model: it answers a summary
// request (Compaction.instruction) with "SUMMARY(n): …" and records it at /mock/last-summary.

private func mockJSON(_ fx: Fixture, _ path: String) async throws -> [String: Any] {
    let url = URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + path)!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private func sentMessages(_ fx: Fixture) async throws -> [[String: Any]] {
    try await mockJSON(fx, "/mock/last-messages")["messages"] as? [[String: Any]] ?? []
}

private func summaries(_ fx: Fixture) async throws -> Int {
    try await mockJSON(fx, "/mock/requests")["summaries"] as? Int ?? 0
}

private func contents(_ messages: [[String: Any]]) -> [String] {
    messages.compactMap { $0["content"] as? String }
}

/// A conversation of `turns` exchanges, each user message about `size` characters.
@MainActor
private func chat(_ fx: Fixture, turns: Int, size: Int = 20) async throws -> ConversationSession {
    let session = try await fx.create()
    for i in 1...turns {
        try await fx.send("turn\(i) " + String(repeating: "w ", count: size / 2), in: session)
    }
    return session
}

@MainActor
private func waitForCompaction(_ session: ConversationSession) async throws {
    try #require(await waitUntil { !session.isCompacting }, "compaction did not end")
}

@Suite(.serialized) @MainActor struct CompactionAppTests {
    @Test func theSettingsAreOnAt80AndKept() throws {
        let fx = try Fixture(baseURL: "http://127.0.0.1:9/v1", defaultModel: "m", mcp: FakeToolHost())
        defer { fx.cleanup() }
        #expect(fx.settings.autoCompaction && fx.settings.compactionThresholdPercent == 80)
        #expect(fx.defaults.object(forKey: "autoCompaction") == nil, "nothing stored until changed")
        fx.settings.compactionThresholdPercent = 99
        #expect(fx.settings.compactionThresholdPercent == 95)
        fx.settings.autoCompaction = false
        let reloaded = AppSettings(defaults: fx.defaults)
        #expect(!reloaded.autoCompaction && reloaded.compactionThresholdPercent == 95)
        fx.defaults.set(5, forKey: "compactionThresholdPercent")
        #expect(AppSettings(defaults: fx.defaults).compactionThresholdPercent == 30)
        #expect(ContextPopover.parseThreshold("85%") == 85 && ContextPopover.parseThreshold("8") == nil)
    }

    @Test func compactNowSummarizesAllButTheNewestExchange() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            #expect(session.isCompacting && session.isBusy)
            try await waitForCompaction(session)
            #expect(session.compactionError == nil)
            let compaction = try #require(session.conversation.compaction)
            #expect(compaction.messageCount == 4 && compaction.summary.hasPrefix("SUMMARY(4): turn1"))
            #expect(session.conversation.messages.count == 6, "nothing is deleted")

            // The summary request: the four messages and the instruction, no tools, no thinking, a fixed length.
            let request = try await mockJSON(fx, "/mock/last-summary")
            #expect(request["max_tokens"] as? Int == Compaction.summaryMaxTokens)
            #expect(request["tools"] == nil)
            let asked = contents(request["messages"] as? [[String: Any]] ?? [])
            #expect(asked.count == 5 && asked.last == Compaction.instruction)

            // The next request: the summary in the system text, then only the newest exchange.
            try await fx.send("next", in: session)
            let sent = try await sentMessages(fx)
            #expect(sent.first?["role"] as? String == "system")
            let system = try #require(sent.first?["content"] as? String)
            #expect(system.contains("<conversation_summary>") && system.contains(compaction.summary))
            let rest = contents(Array(sent.dropFirst()))
            #expect(rest.count == 3 && rest[0].hasPrefix("turn3") && rest[2] == "next")
            #expect(try readPlain(session.fileURL).compaction?.throughMessageID == compaction.throughMessageID)
        }
    }

    @Test func restoringSendsEverythingAgain() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            try await waitForCompaction(session)
            session.restoreFullHistory()
            #expect(session.conversation.compaction == nil)
            try await fx.send("again", in: session)
            let sent = contents(try await sentMessages(fx))
            #expect(sent.count == 7 && sent.first?.hasPrefix("turn1") == true)
            #expect(try readPlain(session.fileURL).compaction == nil)
        }
    }

    @Test func aRollbackIntoTheSummaryDropsIt() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            try await waitForCompaction(session)
            session.rollback(toMessageAt: 2)
            #expect(session.conversation.compaction == nil)
        }
    }

    @Test func nothingToCompactSaysSo() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 1)
            session.compactNow(settings: fx.settings)
            try await waitForCompaction(session)
            #expect(session.conversation.compaction == nil)
            #expect(session.compactionError == nil)
            #expect(session.compactionNotice == "Nothing to compact yet: the newest exchange is always sent in full.")
            #expect(try await summaries(fx) == 0)
        }
    }

    @Test func aSummaryCutOffAtItsLengthIsNotKept() async throws {
        try await withFixture(model: "mock-summary-length") { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            try await waitForCompaction(session)
            #expect(session.conversation.compaction == nil)
            #expect(session.compactionError?.contains("The summary was cut off by its length limit.") == true)
        }
    }

    @Test func aStoppedCompactNowDoesNotEndTheNextOne() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            session.stop()
            session.compactNow(settings: fx.settings)
            #expect(session.isCompacting)
            try await waitForCompaction(session)
            #expect(session.conversation.compaction != nil, "the second run finished and was kept")
        }
    }

    @Test func stopAndLockEndACompactNowAndChangeNothing() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3)
            session.compactNow(settings: fx.settings)
            session.send(text: "while compacting", attachments: [], settings: fx.settings)
            #expect(session.conversation.messages.count == 6, "nothing is sent while compacting")
            session.stop()
            #expect(!session.isCompacting)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(session.conversation.compaction == nil)

            session.compactNow(settings: fx.settings)
            session.close(saving: true)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(session.conversation.compaction == nil && !session.isCompacting)
        }
    }

    /// The context length becomes known (entered by hand): 300 tokens, which a ~200-token message
    /// on top of the mock's count of the last reply (80) crosses at 80%. The mock reports a prompt
    /// of 10 tokens whatever it got, so before this nothing is due.
    @MainActor
    private func smallContext(_ fx: Fixture) {
        fx.state.setManualContextLength(300, provider: fx.provider, model: fx.settings.providers[0].defaultModel)
    }

    @Test func automaticCompactionRunsBeforeTheReplyThatCrossesTheThreshold() async throws {
        try await withFixture { fx in
            let session = try await chat(fx, turns: 3, size: 800)
            #expect(try await summaries(fx) == 0, "no context length known so far")
            smallContext(fx)
            try await fx.send("turn4 " + String(repeating: "w ", count: 400), in: session)
            // A context this small takes the covered messages in two pieces, folded one into the other.
            #expect(try await summaries(fx) == 2)
            let compaction = try #require(session.conversation.compaction)
            #expect(compaction.messageCount == 6)
            #expect(compaction.summary.hasPrefix("SUMMARY("))
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.isComplete && reply.toolNotes == nil)
            // The reply's request carried the summary and the newest turn only.
            let sent = try await sentMessages(fx)
            #expect((sent.first?["content"] as? String)?.contains("<conversation_summary>") == true)
            #expect(contents(Array(sent.dropFirst())).first?.hasPrefix("turn4") == true)
            // The strip now counts the summary and the tail, not the old prompt.
            let usage = session.contextUsage()
            #expect(usage.tokens < 300)
        }
    }

    @Test func automaticCompactionOffOrUnknownLengthSendsAsBefore() async throws {
        try await withFixture { fx in
            fx.settings.autoCompaction = false
            let session = try await chat(fx, turns: 3, size: 800)
            smallContext(fx)
            try await fx.send("turn4 " + String(repeating: "w ", count: 400), in: session)
            #expect(try await summaries(fx) == 0)
            #expect(session.conversation.compaction == nil)
        }
        try await withFixture { fx in
            // No context length known: nothing to measure against.
            let session = try await chat(fx, turns: 4, size: 800)
            #expect(try await summaries(fx) == 0)
            #expect(session.conversation.compaction == nil)
        }
    }

    @Test func aFailedSummaryStillSendsTheWholeHistoryWithANote() async throws {
        try await withFixture(model: "mock-summary-fail") { fx in
            let session = try await chat(fx, turns: 3, size: 800)
            smallContext(fx)
            try await fx.send("turn4 " + String(repeating: "w ", count: 400), in: session)
            #expect(try await summaries(fx) >= 1)
            #expect(session.conversation.compaction == nil)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.isComplete)
            #expect(reply.toolNotes?.first?.kind == ToolNote.compactionFailed)
            #expect(contents(try await sentMessages(fx)).first?.hasPrefix("turn1") == true)
            #expect(MessageRow.toolNoteText(try #require(reply.toolNotes?.first)).hasPrefix("Earlier messages could not be summarized"))
        }
    }
}
