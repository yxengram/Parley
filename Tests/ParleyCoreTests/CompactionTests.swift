import Foundation
import Testing
@testable import ParleyCore

// Context compaction in ParleyCore: the stored marker, what a request carries, the context estimate
// and the pieces of a summary request. Nothing here talks to a server.

private func user(_ text: String) -> Message { Message(role: .user, content: text) }
private func reply(_ text: String, prompt: Int? = nil, completion: Int? = nil) -> Message {
    var message = Message(role: .assistant, content: text)
    if let prompt { message.usage = TokenUsage(promptTokens: prompt, completionTokens: completion ?? 0) }
    return message
}

/// u0 a1 u2 a3 u4 a5, compacted through a3.
private func compacted() -> Conversation {
    let messages = [user("u0"), reply("a1"), user("u2"), reply("a3"), user("u4"), reply("a5")]
    return Conversation(messages: messages, compaction: ConversationCompaction(
        summary: "They talked about u0 to a3.", throughMessageID: messages[3].id, countsStaleThroughID: messages[5].id,
        model: "m", messageCount: 4))
}

@Suite struct CompactionStorageTests {
    @Test func aFileWithoutItDecodesAndIsWrittenWithoutIt() throws {
        let conversation = try ConversationFile.decodePlain(try ConversationFile.encode(Conversation(messages: [user("hi")]), encryption: nil))
        #expect(conversation.compaction == nil)
        let text = String(decoding: try ConversationFile.encode(conversation, encryption: nil), as: UTF8.self)
        #expect(!text.contains("compaction"))
    }

    @Test func itSurvivesARoundTrip() throws {
        let conversation = compacted()
        let decoded = try ConversationFile.decodePlain(try ConversationFile.encode(conversation, encryption: nil))
        #expect(decoded.compaction?.summary == conversation.compaction?.summary)
        #expect(decoded.compaction?.throughMessageID == conversation.compaction?.throughMessageID)
        #expect(decoded.compaction?.countsStaleThroughID == conversation.compaction?.countsStaleThroughID)
        #expect(decoded.compaction?.messageCount == 4)
        #expect(decoded.compactionBoundary == 3)
    }

    @Test func anEncryptedFileHoldsNoSummaryInTheClear() throws {
        let key = try ConversationCrypto.newKey(password: "test-password", iterations: 1000)
        let data = try ConversationFile.encode(compacted(), encryption: key)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("They talked") && !text.contains("compaction"))
        #expect(try ConversationFile.decodeEncrypted(data, key: key).compaction?.summary == "They talked about u0 to a3.")
    }

    @Test func aRollbackIntoTheSummaryDropsIt() {
        var kept = compacted()
        kept.truncate(keepingThrough: 3)
        #expect(kept.compaction != nil, "the summary still covers exactly what is there")
        var dropped = compacted()
        dropped.truncate(keepingThrough: 2)
        #expect(dropped.compaction == nil)
        #expect(dropped.effectiveHistory.messages.count == 3)
    }

    @Test func aForkKeepsItOnlyWhenItHoldsEverythingItCovers() {
        let conversation = compacted()
        for through in [3, 4] {
            let fork = conversation.forked(through: through)
            #expect(fork.compaction?.summary == conversation.compaction?.summary)
            #expect(fork.compaction?.throughMessageID == conversation.compaction?.throughMessageID)
            // a5, the stale mark, is not in the fork: the mark moves to its last message.
            #expect(fork.compaction?.countsStaleThroughID == fork.messages.last?.id)
        }
        #expect(conversation.forked(through: 2).compaction == nil)
    }
}

@Suite struct EffectiveHistoryTests {
    @Test func withoutACompactionItIsTheWholeHistory() {
        let conversation = Conversation(messages: [user("a"), reply("b")])
        let effective = conversation.effectiveHistory
        #expect(effective.messages.map(\.id) == conversation.messages.map(\.id))
        #expect(effective.summaryBlock == nil && effective.anchorsFrom == 0 && effective.coveredCount == 0)
        #expect(effective.systemText(prompt: "sys") == "sys")
    }

    @Test func withOneItIsTheSummaryAndTheMessagesAfterIt() throws {
        let conversation = compacted()
        let effective = conversation.effectiveHistory
        #expect(effective.messages.map(\.content) == ["u4", "a5"])
        #expect(effective.coveredCount == 4)
        let block = try #require(effective.summaryBlock)
        #expect(block.hasPrefix("<conversation_summary>\n") && block.hasSuffix("They talked about u0 to a3.\n</conversation_summary>"))
        #expect(effective.systemText(prompt: "sys") == "sys\n\n" + block)
        #expect(effective.systemText(prompt: "  ") == block)
        // a5 existed when the summary was made: its count took the whole history.
        #expect(effective.anchorsFrom == 2)
    }

    @Test func aBoundaryThatIsGoneMeansNoCompaction() {
        var conversation = compacted()
        conversation.messages.remove(at: 3)
        #expect(conversation.compactionBoundary == nil)
        #expect(conversation.effectiveHistory.summaryBlock == nil)
        #expect(conversation.effectiveHistory.messages.count == 5)
    }

    @Test func aRollbackPastTheStaleMarkLeavesNoAnchorUntilTheNextReply() {
        var conversation = compacted()
        conversation.truncate(keepingThrough: 4)
        #expect(conversation.compaction?.countsStaleThroughID == conversation.messages[4].id)
        #expect(conversation.effectiveHistory.anchorsFrom == 1, "u4 is all that is left, and it predates the summary")
        conversation.messages.append(reply("a5'", prompt: 300, completion: 10))
        let effective = conversation.effectiveHistory
        #expect(effective.anchorsFrom == 1)
        #expect(ContextBudget.usage(messages: effective.messages, systemPrompt: "", anchorsFrom: effective.anchorsFrom).tokens == 310)
        #expect(conversation.forked(through: 3).compaction?.countsStaleThroughID == conversation.messages[3].id)
    }
}

@Suite struct CompactionRequestTests {
    private func systemText(_ body: [String: Any]) -> String? {
        let messages = body["messages"] as? [[String: Any]] ?? []
        guard messages.first?["role"] as? String == "system" else { return nil }
        return messages.first?["content"] as? String
    }

    @Test func theSummaryGoesAfterThePromptAndTheReActBlock() throws {
        let conversation = compacted()
        let effective = conversation.effectiveHistory
        var options = ChatRequestOptions(model: "m", systemPrompt: "Be brief.")
        options.historySummary = effective.summaryBlock
        let body = ChatClient.buildRequestBody(messages: effective.messages, options: options)
        let block = try #require(effective.summaryBlock)
        #expect(systemText(body) == "Be brief.\n\n" + block)
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.dropFirst().compactMap { $0["content"] as? String } == ["u4", "a5"])

        options.react = ReActRequest(tools: [], nonce: "n")
        let react = try #require(systemText(ChatClient.buildRequestBody(messages: effective.messages, options: options)))
        #expect(react.hasPrefix("Be brief.\n\n") && react.hasSuffix("\n\n" + block))

        var bare = ChatRequestOptions(model: "m")
        bare.historySummary = block
        #expect(systemText(ChatClient.buildRequestBody(messages: effective.messages, options: bare)) == block)
    }

    @Test func noSummaryIsTheBodyAsBefore() throws {
        let messages = [user("a"), reply("b"), user("c")]
        var options = ChatRequestOptions(model: "m", systemPrompt: "sys")
        let before = try JSONSerialization.data(withJSONObject: ChatClient.buildRequestBody(messages: messages, options: options), options: .sortedKeys)
        options.historySummary = nil
        let after = try JSONSerialization.data(withJSONObject: ChatClient.buildRequestBody(messages: messages, options: options), options: .sortedKeys)
        #expect(before == after)
        options.historySummary = "  "
        let blank = try JSONSerialization.data(withJSONObject: ChatClient.buildRequestBody(messages: messages, options: options), options: .sortedKeys)
        #expect(blank == before)
    }
}

@Suite struct CompactionUsageTests {
    @Test func countsFromBeforeTheSummaryAreNotAnchors() {
        let conversation = compacted()
        let effective = conversation.effectiveHistory
        var tail = effective.messages
        tail[1].usage = TokenUsage(promptTokens: 9000, completionTokens: 100)
        let stale = ContextBudget.usage(messages: tail, systemPrompt: effective.systemText(prompt: ""), anchorsFrom: effective.anchorsFrom)
        #expect(stale.isEstimated && stale.tokens < 200)
        let anchored = ContextBudget.usage(messages: tail, systemPrompt: effective.systemText(prompt: ""))
        #expect(anchored.tokens == 9100, "without the mark the old count would anchor")
    }

    @Test func aReplyAfterTheSummaryAnchorsAgain() {
        var conversation = compacted()
        conversation.messages.append(user("u6"))
        conversation.messages.append(reply("a7", prompt: 500, completion: 20))
        let effective = conversation.effectiveHistory
        let usage = ContextBudget.usage(messages: effective.messages, systemPrompt: effective.systemText(prompt: ""), anchorsFrom: effective.anchorsFrom)
        #expect(usage.tokens == 520 && !usage.isEstimated)
    }

    @Test func dueOnlyWithAKnownLimit() {
        let usage = ContextUsage(tokens: 800, isEstimated: true)
        #expect(Compaction.isDue(usage: usage, limit: ContextLimit(tokens: 1000, source: .manual), thresholdPercent: 80))
        #expect(!Compaction.isDue(usage: usage, limit: ContextLimit(tokens: 1001, source: .manual), thresholdPercent: 80))
        #expect(!Compaction.isDue(usage: usage, limit: nil, thresholdPercent: 80))
    }
}

@Suite struct CompactionBoundaryTests {
    private func turns(_ count: Int, size: Int = 40) -> [Message] {
        (0..<count).flatMap { i in [user("question \(i) " + String(repeating: "x", count: size)), reply("answer \(i) " + String(repeating: "y", count: size))] }
    }

    @Test func theTailStartsAtAUserTurnAndKeepsTheNewestWhole() throws {
        let messages = turns(6)
        // No room for more than the last turn.
        let through = try #require(Compaction.boundary(in: messages, current: nil, limitTokens: 10))
        #expect(through == 9)
        #expect(messages[through + 1].role == .user)
        // Room for about three turns of ~30 tokens.
        let roomy = try #require(Compaction.boundary(in: messages, current: nil, limitTokens: 400))
        #expect(messages[roomy + 1].role == .user && roomy < 9)
    }

    @Test func leavingOutTheReplyBeingWritten() throws {
        var messages = turns(3)
        messages.append(user("now"))
        messages.append(reply(""))
        #expect(try #require(Compaction.boundary(in: messages, current: nil, limitTokens: 10, before: messages.count - 1)) == 5)
    }

    @Test func nothingToSummarize() {
        #expect(Compaction.boundary(in: [user("only")], current: nil, limitTokens: 10) == nil)
        #expect(Compaction.boundary(in: [], current: nil, limitTokens: 10) == nil)
        let messages = turns(3)
        #expect(Compaction.boundary(in: messages, current: 3, limitTokens: 10) == nil, "never back to or before the current one")
        let failedOnly = [reply(""), user("hi")]
        #expect(Compaction.boundary(in: failedOnly, current: nil, limitTokens: 10) == nil)
    }

    @Test func aNewSummaryCoversMore() throws {
        let messages = turns(6)
        #expect(try #require(Compaction.boundary(in: messages, current: 3, limitTokens: 10)) == 9)
    }
}

@Suite struct SummaryRequestTests {
    @Test func theMessagesEndInTheInstructionAndAlternate() {
        var picture = Message(role: .user, content: "look", attachments: [Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([1]))])
        picture.reasoning = nil
        var thinking = reply("seen")
        thinking.reasoning = "secret thoughts"
        let out = Compaction.requestMessages(previousSummary: "Before: hello.", messages: [picture, thinking, reply(""), user("and then")])
        // summary + picture joined (both user), seen, and then (failed reply skipped), instruction.
        #expect(out.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(out[0].content == "Summary of the conversation so far:\n\nBefore: hello.\n\nlook\n\n[An image was attached here.]")
        #expect(out[0].attachments.isEmpty)
        #expect(out[1].reasoning == nil)
        #expect(out.last?.content == Compaction.instruction)
    }

    @Test func noPreviousSummary() {
        let out = Compaction.requestMessages(previousSummary: nil, messages: [user("a"), reply("b")])
        #expect(out.map(\.content) == ["a", "b", Compaction.instruction])
    }

    @Test func everyPieceAlternatesFromAUserTurn() {
        // A later piece that starts with a reply, after a summary.
        let later = Compaction.requestMessages(previousSummary: "So far.", messages: [reply("a2"), user("u3"), reply("a3")])
        #expect(later.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(later[0].content == "Summary of the conversation so far:\n\nSo far.")
        // The same without a summary.
        let first = Compaction.requestMessages(previousSummary: nil, messages: [reply("a2"), user("u3")])
        #expect(first.map(\.content) == ["(The conversation began earlier.)", "a2", "u3", "(No reply yet.)", Compaction.instruction])
        // Two user turns left together by a skipped failed reply are joined.
        let joined = Compaction.requestMessages(previousSummary: nil, messages: [user("u1"), reply(""), user("u2"), reply("a2")])
        #expect(joined.map(\.content) == ["u1\n\nu2", "a2", Compaction.instruction])
        for out in [later, first, joined] {
            #expect(zip(out, out.dropFirst()).allSatisfy { $0.role != $1.role } && out.first?.role == .user)
        }
    }

    @Test func chunksFitTheirBudget() {
        let messages = (0..<10).map { user("message \($0) " + String(repeating: "z", count: 400)) }
        let chunks = Compaction.chunks(messages, budgetTokens: 250)
        #expect(chunks.count == 5 && chunks.allSatisfy { $0.count == 2 })
        #expect(chunks.flatMap { $0 }.map(\.id) == messages.map(\.id))
        #expect(Compaction.chunks([user(String(repeating: "w", count: 4000))], budgetTokens: 10).count == 1)
    }
}
