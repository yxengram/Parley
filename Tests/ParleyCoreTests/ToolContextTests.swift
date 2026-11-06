import Foundation
import Testing
@testable import ParleyCore

// How tool rounds count toward the context strip.

private func round(content: String = "", result: String?, usage: TokenUsage? = nil, reasoning: String? = nil) -> ToolRound {
    ToolRound(content: content, reasoning: reasoning,
              calls: [ToolCallRecord(id: "c", name: "s__t", arguments: "{}", startedAt: Date(),
                                     result: result.map { ToolCallResult(status: .completed, text: $0) })],
              usage: usage)
}

@Suite struct ToolContextTests {
    @Test func aMessageWithoutRoundsCostsWhatItDid() {
        let message = Message(role: .assistant, content: "hello there")
        #expect(ContextBudget.estimateTokens(message: message) == ContextBudget.messageOverhead + ContextBudget.estimateTokens("hello there"))
    }

    @Test func roundsAreEstimated() {
        var message = Message(role: .assistant, content: "")
        message.toolRounds = [round(content: "abcd", result: "efgh")]
        let expected = ContextBudget.messageOverhead + 1                                     // the round's text
            + 8 + ContextBudget.estimateTokens("s__t") + ContextBudget.estimateTokens("{}")  // the call
            + ContextBudget.messageOverhead + 1                                              // the result
        #expect(ContextBudget.estimateTokens(message: message) == expected)
    }

    @Test func aRoundOfAUserlessReplyIsNotSkippedAsEmpty() {
        var message = Message(role: .assistant, content: "")
        message.toolRounds = [round(result: "result text")]
        let used = ContextBudget.usage(messages: [message], systemPrompt: "")
        #expect(used.tokens > 0)
        #expect(used.isEstimated)
    }

    @Test func finalUsageAlreadyHoldsEveryRound() {
        var message = Message(role: .assistant, content: "Done.")
        message.toolRounds = [round(result: String(repeating: "x", count: 4000), usage: TokenUsage(promptTokens: 50, completionTokens: 5))]
        message.usage = TokenUsage(promptTokens: 1000, completionTokens: 20)
        let used = ContextBudget.usage(messages: [message], systemPrompt: "")
        #expect(used.tokens == 1020)
        #expect(!used.isEstimated)
    }

    @Test func aStoppedReplyAnchorsOnItsLastCountedRound() {
        let earlier = Message(role: .assistant, content: "old", usage: TokenUsage(promptTokens: 10, completionTokens: 2))
        var stopped = Message(role: .assistant, content: "")
        stopped.toolRounds = [round(result: "abcd", usage: TokenUsage(promptTokens: 100, completionTokens: 10))]
        let used = ContextBudget.usage(messages: [earlier, Message(role: .user, content: "go"), stopped], systemPrompt: "")
        #expect(used.tokens == 110 + ContextBudget.messageOverhead + 1)
        #expect(used.isEstimated)
    }

    @Test func roundReasoningIsLeftOut() {
        var stopped = Message(role: .assistant, content: "")
        stopped.toolRounds = [round(result: "", usage: TokenUsage(promptTokens: 100, completionTokens: 50), reasoning: String(repeating: "t", count: 40))]
        let expected = 150 - 10 + ContextBudget.messageOverhead + ContextBudget.estimateTokens(ToolResultText.empty)
        #expect(ContextBudget.usage(messages: [stopped], systemPrompt: "").tokens == expected)
    }

    @Test func inFlightRoundsDoNotCountTwiceWhileWaiting() {
        // A round with usage, its result pending (an approval card is up): only the anchor counts.
        var reply = Message(role: .assistant, content: "")
        reply.toolRounds = [round(result: nil, usage: TokenUsage(promptTokens: 100, completionTokens: 10))]
        let waiting = ContextBudget.usage(messages: [reply], systemPrompt: "", inFlightID: reply.id)
        #expect(waiting.tokens == 110)
        reply.toolRounds?[0].calls[0].result = ToolCallResult(status: .completed, text: "abcd")
        let resolved = ContextBudget.usage(messages: [reply], systemPrompt: "", inFlightID: reply.id)
        #expect(resolved.tokens == 110 + ContextBudget.messageOverhead + 1)
    }

    @Test func inFlightRoundsWithoutUsageAreEstimatedAfterTheAnchor() {
        let earlier = Message(role: .assistant, content: "old", usage: TokenUsage(promptTokens: 10, completionTokens: 2))
        var reply = Message(role: .assistant, content: "streaming text the live count covers")
        reply.toolRounds = [round(result: "abcd")]
        let used = ContextBudget.usage(messages: [earlier, reply], systemPrompt: "", inFlightID: reply.id, liveCompletionTokens: 3)
        #expect(used.tokens == 12 + ContextBudget.estimateTokens(round: reply.toolRounds![0]) + 3)
    }

    @Test func definitionsCountOnce() {
        let plain = ContextBudget.usage(messages: [Message(role: .user, content: "hi")], systemPrompt: "")
        let unanchored = ContextBudget.usage(messages: [Message(role: .user, content: "hi")], systemPrompt: "", toolDefinitionTokens: 300)
        #expect(unanchored.tokens == plain.tokens + 300)

        var counted = Message(role: .assistant, content: "ok", usage: TokenUsage(promptTokens: 400, completionTokens: 2))
        counted.toolDefinitionTokens = 300
        #expect(ContextBudget.usage(messages: [counted], systemPrompt: "", toolDefinitionTokens: 300).tokens == 402)
        // A server enabled after that reply adds only what is new.
        #expect(ContextBudget.usage(messages: [counted], systemPrompt: "", toolDefinitionTokens: 500).tokens == 602)
    }

    @Test func toolResultBudget() {
        #expect(ContextBudget.toolResultBudget(configured: 32_000, limit: nil, used: 0) == 32_000)
        let big = ContextLimit(tokens: 100_000, source: .server)
        #expect(ContextBudget.toolResultBudget(configured: 32_000, limit: big, used: 1_000) == 32_000)
        let small = ContextLimit(tokens: 8_192, source: .server)
        #expect(ContextBudget.toolResultBudget(configured: 32_000, limit: small, used: 4_192) == 8_000)
        #expect(ContextBudget.toolResultBudget(configured: 32_000, limit: small, used: 8_190) == 2_000)
        #expect(ContextBudget.toolResultBudget(configured: 1_000, limit: small, used: 8_190) == 1_000)
    }

    @Test func modelInfoCarriesIgnoresTools() {
        var info = ModelContextInfo(model: "m")
        var other = ModelContextInfo(model: "m")
        other.ignoresTools = true
        info.merge(other)
        #expect(info.ignoresTools)
    }
}
