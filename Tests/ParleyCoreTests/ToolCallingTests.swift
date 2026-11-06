import Foundation
import Testing
@testable import ParleyCore

// Streamed tool_calls in every shape the servers produce, folded into whole calls.

private func parseAll(_ payloads: [String]) throws -> StreamAccumulator {
    var accumulator = StreamAccumulator()
    for payload in payloads {
        if let delta = try ChunkParser.parse(payload) { accumulator.apply(delta) }
    }
    accumulator.finish()
    return accumulator
}

private func chunk(_ delta: String, finish: String = "null") -> String {
    #"{"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
}

@Suite struct ToolChunkTests {
    @Test func lmStudioFragments() throws {
        let acc = try parseAll([
            chunk(#"{"role":"assistant","content":""}"#),
            chunk(#"{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"srv__read","arguments":""}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"id":null,"type":null,"function":{"name":null,"arguments":"{\"pa"}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"/a\"}"}}]}"#),
            chunk("{}", finish: #""tool_calls""#),
        ])
        let calls = acc.toolCalls.finalCalls()
        try #require(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].name == "srv__read")
        #expect(calls[0].arguments == #"{"path":"/a"}"#)
        #expect(acc.finishReason == "tool_calls")
    }

    @Test func llamaCppFirstFragmentHasNoArgumentsKey() throws {
        let acc = try parseAll([
            chunk(#"{"role":"assistant","content":null}"#),
            chunk(#"{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"t"}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}"#),
        ])
        #expect(acc.toolCalls.finalCalls().map(\.arguments) == ["{}"])
    }

    @Test func llamaCppResentIDAndNameSetsTheName() throws {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(index: 0, id: "x", name: "get_w"))
        acc.apply(ToolCallDelta(index: 0, id: "x", name: "get_weather"))
        acc.apply(ToolCallDelta(index: 0, arguments: "{}"))
        #expect(acc.finalCalls().map(\.name) == ["get_weather"])
    }

    @Test func aNameWithoutAnIDAppends() {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(index: 0, id: "x", name: "get_"))
        acc.apply(ToolCallDelta(index: 0, name: "weather"))
        #expect(acc.finalCalls().map(\.name) == ["get_weather"])
    }

    @Test func vllmBothFragmentsInOneArrayBesideContent() throws {
        let acc = try parseAll([
            chunk(#"{"content":"Let me look.","tool_calls":[{"index":0,"type":"function","id":"h","function":{"name":"t"}},{"index":0,"function":{"arguments":"{\"a\":1}"}}]}"#),
        ])
        #expect(acc.content == "Let me look.")
        #expect(acc.toolCalls.finalCalls().map(\.arguments) == [#"{"a":1}"#])
    }

    @Test func ollamaWholeCallInOneChunk() throws {
        let acc = try parseAll([
            chunk(#"{"tool_calls":[{"id":"o","index":0,"type":"function","function":{"name":"t","arguments":"{\"a\":1}"}}]}"#),
            chunk("{}", finish: #""tool_calls""#),
        ])
        #expect(acc.toolCalls.finalCalls().count == 1)
    }

    @Test func strataClosingBraceAlwaysSent() throws {
        let acc = try parseAll([
            chunk(#"{"role":"assistant","content":""}"#),
            chunk(#"{"tool_calls":[{"index":0,"id":"s","type":"function","function":{"name":"t","arguments":""}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}"#),
        ])
        #expect(acc.toolCalls.finalCalls().map(\.arguments) == ["{}"])
    }

    @Test func nonStreamingMessageUsesArrayPositionAndObjectArguments() throws {
        let acc = try parseAll([
            #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"a","type":"function","function":{"name":"one","arguments":{"b":2,"a":1}}},{"id":"b","type":"function","function":{"name":"two","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
        ])
        let calls = acc.toolCalls.finalCalls()
        try #require(calls.map(\.name) == ["one", "two"])
        #expect(calls[0].arguments == #"{"a":1,"b":2}"#)
    }

    @Test func parallelCallsInterleaved() throws {
        let acc = try parseAll([
            chunk(#"{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"second","arguments":""}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"first","arguments":""}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"n\":"}},{"index":1,"function":{"arguments":"{\"m\":"}}]}"#),
            chunk(#"{"tool_calls":[{"index":1,"function":{"arguments":"2}"}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}"#),
        ])
        let calls = acc.toolCalls.finalCalls()
        #expect(calls.map(\.name) == ["first", "second"])
        #expect(calls.map(\.arguments) == [#"{"n":1}"#, #"{"m":2}"#])
    }

    @Test func aToolOnlyDeltaIsNotDropped() throws {
        let delta = try ChunkParser.parse(chunk(#"{"tool_calls":[{"index":0,"id":"a","function":{"name":"t"}}]}"#))
        #expect(delta?.toolCalls.count == 1)
    }

    @Test func missingIndexNewIDOpensASlot() {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(id: "a", name: "one", arguments: "{"))
        acc.apply(ToolCallDelta(arguments: "}"))
        acc.apply(ToolCallDelta(id: "b", name: "two"))
        acc.apply(ToolCallDelta(arguments: "{}"))
        #expect(acc.finalCalls().map(\.arguments) == ["{}", "{}"])
        #expect(acc.finalCalls().map(\.name) == ["one", "two"])
    }

    @Test func serversThatNumberEveryCallZero() {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(index: 0, id: "a", name: "one", arguments: "{}"))
        acc.apply(ToolCallDelta(index: 0, id: "b", name: "two", arguments: "{}"))
        #expect(acc.finalCalls().map(\.name) == ["one", "two"])
    }

    @Test func blankAndRepeatedIDsAreReplaced() throws {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(index: 0, id: "", name: "a"))
        acc.apply(ToolCallDelta(index: 1, id: "same", name: "b"))
        acc.apply(ToolCallDelta(index: 2, id: "same", name: "c"))
        acc.apply(ToolCallDelta(index: 3, id: "earlier", name: "d"))
        let ids = acc.finalCalls(existingIDs: ["earlier"]).map(\.id)
        try #require(ids.count == 4)
        #expect(Set(ids).count == 4)
        #expect(ids[1] == "same")
        #expect(!ids.contains("earlier"))
        #expect(ids[0].hasPrefix("call_") && ids[0].count == 13)
    }

    @Test func nameLessFragmentsAreDropped() {
        var acc = ToolCallAccumulator()
        acc.apply(ToolCallDelta(index: 0, arguments: "{}"))
        #expect(acc.finalCalls().isEmpty)
    }

    @Test func toolChunksCountForTheMeter() {
        var meter = GenerationMeter(requestStartedAt: Date(timeIntervalSince1970: 0))
        meter.record(ChatDelta(toolCalls: [ToolCallDelta(index: 0, arguments: "{")]), now: Date(timeIntervalSince1970: 1))
        meter.record(ChatDelta(toolCalls: [ToolCallDelta(index: 0, arguments: "}")]), now: Date(timeIntervalSince1970: 2))
        #expect(meter.chunkCount == 2)
        #expect(meter.timeToFirstToken == 1)
        #expect(meter.finalStats() != nil)
    }
}

@Suite struct ToolReplayTextTests {
    @Test func argumentsParsing() {
        #expect(ToolArguments.parse("") == [:])
        #expect(ToolArguments.parse("  ") == [:])
        #expect(ToolArguments.parse("null") == [:])
        #expect(ToolArguments.parse(#"{"a":1}"#) == ["a": .int(1)])
        #expect(ToolArguments.parse("[1]") == nil)
        #expect(ToolArguments.parse(#"{"a":"#) == nil)
    }

    @Test func replayArgumentsAreAlwaysAnObject() {
        func replay(_ raw: String) -> String { ToolCallRecord(id: "i", name: "n", arguments: raw).replayArguments }
        #expect(replay("") == "{}")
        #expect(replay("null") == "{}")
        #expect(replay(#"{"a":"#) == "{}")
        #expect(replay("[1]") == "{}")
        #expect(replay(#" {"a":1} "#) == #"{"a":1}"#)
    }

    @Test func unresolvedCallsSynthesizeByStartedAt() {
        var call = ToolCallRecord(id: "i", name: "n", arguments: "{}")
        #expect(call.replayResult == ToolResultText.notRun)
        call.startedAt = Date()
        #expect(call.replayResult == ToolResultText.interrupted)
        call.result = ToolCallResult(status: .completed, text: "")
        #expect(call.replayResult == ToolResultText.empty)
        call.result = ToolCallResult(status: .completed, text: "fine")
        #expect(call.replayResult == "fine")
    }

    @Test func visibleTextJoinsRounds() {
        var message = Message(role: .assistant, content: "final")
        #expect(message.visibleText == "final")
        message.toolRounds = [ToolRound(content: "first", calls: []), ToolRound(content: " ", calls: [])]
        #expect(message.visibleText == "first\n\nfinal")
    }

    @Test func latestStatsFallsBackToTheLastRound() {
        var message = Message(role: .assistant, content: "")
        let stats = GenerationStats(tokensPerSecond: 5)
        message.toolRounds = [ToolRound(content: "", calls: [], stats: stats), ToolRound(content: "", calls: [])]
        #expect(message.latestStats == stats)
        message.stats = GenerationStats(tokensPerSecond: 9)
        #expect(message.latestStats?.tokensPerSecond == 9)
    }

    @Test func resultTexts() {
        #expect(ToolResultText.timedOut(seconds: 120) == "The tool did not finish within 120 seconds and was cancelled. It may have partly run.")
        #expect(ToolResultText.unknownTool("x") == "The tool was not called: no tool named x is available.")
        #expect(ToolResultText.failed("boom") == "The tool call failed: boom")
        let long = String(repeating: "a", count: 5000)
        #expect(ToolResultText.malformed(reason: "not valid JSON", raw: long).count < 2200)
    }
}
