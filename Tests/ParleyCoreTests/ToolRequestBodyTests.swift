import Foundation
import Testing
@testable import ParleyCore

// What goes on the wire. First the regression: with no MCP in use, every body is what it was
// before tool calling existed. Then the tool-shaped bodies.

private func sortedJSON(_ body: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
}

/// The history the goldens were dumped from: the assistant, system and attachment paths.
private func goldenHistory() -> [Message] {
    var failed = Message(role: .assistant, content: "   ")
    failed.error = "boom"
    let answer = Message(role: .assistant, content: "Paris.", reasoning: "It is a capital.", reasoningDuration: 1.5,
                         usage: TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
    return [
        Message(role: .system, content: "history system"),
        Message(role: .system, content: "  "),
        Message(role: .user, content: "read this", attachments: [
            ParleyCore.Attachment(kind: .text, filename: "a\"b.txt", mimeType: "text/plain", text: "file body"),
        ]),
        Message(role: .assistant, content: ""),
        failed,
        Message(role: .user, content: "and this", attachments: [
            ParleyCore.Attachment(kind: .image, filename: "p.png", mimeType: "image/png", data: Data([1, 2, 3, 4])),
            ParleyCore.Attachment(kind: .image, filename: "q", mimeType: "", data: Data([5, 6])),
            ParleyCore.Attachment(kind: .text, filename: "b.txt", mimeType: "text/plain", text: "more"),
        ]),
        answer,
        Message(role: .user, content: "", attachments: [ParleyCore.Attachment(kind: .image, filename: "r.png", mimeType: "image/png", data: Data([7]))]),
        Message(role: .assistant, content: "Partial", isComplete: false),
        Message(role: .user, content: "last 世界 \"quoted\" \n newline"),
    ]
}

private let aTool = ChatTool(name: "srv__echo", description: "Echoes.", parameters: .object([
    "type": .string("object"),
    "properties": .object(["text": .object(["type": .string("string")])]),
]))

private func completedCall(id: String = "call_1", name: String = "srv__echo", arguments: String = #"{"text":"hi"}"#, result: String = "hi") -> ToolCallRecord {
    ToolCallRecord(id: id, name: name, arguments: arguments, serverName: "srv", toolName: "echo", startedAt: Date(),
                   result: ToolCallResult(status: .completed, text: result))
}

private func replyWithRound(final: String = "Done.") -> Message {
    var reply = Message(role: .assistant, content: final, reasoning: "final thoughts")
    reply.toolRounds = [ToolRound(content: "", reasoning: "round thoughts", calls: [completedCall()])]
    return reply
}

@Suite struct NoToolsRegressionTests {
    private func kind(_ name: String) -> InferenceServerKind? {
        name == "nil" ? nil : InferenceServerKind(rawValue: name)
    }

    /// Without MCP in use the body must not change, for every server kind: the same canonical JSON
    /// as the code before tools, whichever way "no tools" is spelled.
    @Test func bodiesAreByteIdenticalForEveryServerKind() throws {
        let lines = noToolsGoldenBodies.split(separator: "\n").map(String.init)
        #expect(lines.count == 252)
        let kinds = Set(lines.map { String($0.prefix { $0 != "|" }) })
        #expect(kinds == ["nil", "lmStudio", "llamaCpp", "vLLM", "ollama", "strata", "hosted"])
        let history = goldenHistory()
        var emptyRounds = history
        emptyRounds[6].toolRounds = []
        for line in lines {
            let f = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            var options = ChatRequestOptions(model: "m", systemPrompt: " sys ", temperature: 0.25, maxTokens: 64,
                                             reasoningEffort: f[1] == "nil" ? nil : ReasoningEffort(rawValue: f[1]))
            options.serverKind = kind(f[0])
            options.disablesThinking = f[2] == "true"
            options.omitsThinkingOff = f[3] == "true"
            options.reasoningBudgetTokens = Int(f[4])
            let usage = f[5] == "true"
            let golden = f[6].replacingOccurrences(of: "§", with: noToolsGoldenMessages)

            #expect(try sortedJSON(ChatClient.buildRequestBody(messages: history, options: options, includeUsage: usage)) == golden, "\(line)")
            var emptyList = options
            emptyList.tools = []
            #expect(try sortedJSON(ChatClient.buildRequestBody(messages: history, options: emptyList, includeUsage: usage)) == golden, "\(line)")
            var omitted = options
            omitted.tools = [aTool]
            omitted.omitsTools = true
            #expect(try sortedJSON(ChatClient.buildRequestBody(messages: history, options: omitted, includeUsage: usage)) == golden, "\(line)")
            #expect(try sortedJSON(ChatClient.buildRequestBody(messages: emptyRounds, options: options, includeUsage: usage)) == golden, "\(line)")
        }
    }

    /// Key order itself is not stable between processes, so "byte-identical" also needs the very
    /// bytes the old writing call gives: no sorted keys without tools.
    @Test func withoutToolsTheBodyIsWrittenAsBefore() throws {
        let options = ChatRequestOptions(model: "m", systemPrompt: "s")
        let body = ChatClient.buildRequestBody(messages: goldenHistory(), options: options, includeUsage: true)
        #expect(try ChatClient.encodeBody(body, options: options) == JSONSerialization.data(withJSONObject: body))
        var withTools = options
        withTools.tools = [aTool]
        #expect(try ChatClient.encodeBody(body, options: withTools) == JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        var refused = withTools
        refused.omitsTools = true
        #expect(try ChatClient.encodeBody(body, options: refused) == JSONSerialization.data(withJSONObject: body))
    }

    @Test func newFieldsLeaveNoTraceInAConversationWithoutTools() throws {
        let conversation = Conversation(settings: ConversationSettings(model: "m"), messages: goldenHistory())
        let text = String(decoding: try ConversationFile.encode(conversation, encryption: nil), as: UTF8.self)
        for key in ["toolRounds", "toolNotes", "toolDefinitionTokens", "mcpServerIDs"] {
            #expect(!text.contains(key))
        }
    }
}

@Suite struct ToolRequestBodyTests {
    private func options(tools: [ChatTool]? = [aTool]) -> ChatRequestOptions {
        var o = ChatRequestOptions(model: "m")
        o.tools = tools
        return o
    }

    private func messages(_ history: [Message], _ options: ChatRequestOptions) -> [[String: Any]] {
        ChatClient.buildRequestBody(messages: history, options: options)["messages"] as? [[String: Any]] ?? []
    }

    @Test func toolsGoOutAsFunctions() throws {
        let body = ChatClient.buildRequestBody(messages: [Message(role: .user, content: "hi")], options: options())
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "srv__echo")
        #expect(function["description"] as? String == "Echoes.")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(body["tool_choice"] == nil)
    }

    @Test func noDescriptionKeyWhenThereIsNone() throws {
        let tool = ChatTool(name: "t", parameters: .object(["type": .string("object")]))
        let body = ChatClient.buildRequestBody(messages: [], options: options(tools: [tool]))
        let function = try #require((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(function["description"] == nil)
    }

    @Test func emptyToolsAreNeverSent() {
        #expect(ChatClient.buildRequestBody(messages: [], options: options(tools: []))["tools"] == nil)
        #expect(ChatClient.buildRequestBody(messages: [], options: options(tools: nil))["tools"] == nil)
    }

    @Test func structuredReplay() throws {
        let sent = messages([Message(role: .user, content: "hi"), replyWithRound()], options())
        try #require(sent.map { $0["role"] as? String } == ["user", "assistant", "tool", "assistant"])
        let call = try #require((sent[1]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_1")
        #expect(call["type"] as? String == "function")
        let function = try #require(call["function"] as? [String: Any])
        #expect(function["name"] as? String == "srv__echo")
        #expect(function["arguments"] as? String == #"{"text":"hi"}"#)
        // An empty round leaves `content` out: LM Studio's documented form.
        #expect(sent[1]["content"] == nil)
        #expect(sent[2]["tool_call_id"] as? String == "call_1")
        #expect(sent[2]["name"] as? String == "srv__echo")
        #expect(sent[2]["content"] as? String == "hi")
        #expect(sent[3]["content"] as? String == "Done.")
    }

    @Test func roundTextIsKeptAndReasoningNeverSent() throws {
        var reply = replyWithRound(final: "")
        reply.toolRounds?[0].content = "Let me look."
        let sent = messages([reply], options())
        try #require(sent.count == 2)
        #expect(sent[0]["content"] as? String == "Let me look.")
        let text = try sortedJSON(ChatClient.buildRequestBody(messages: [reply], options: options()))
        #expect(!text.contains("thoughts"))
        #expect(!text.contains("reasoning"))
    }

    @Test func unresolvedAndMalformedCallsReplayValidly() throws {
        var reply = Message(role: .assistant, content: "")
        reply.toolRounds = [ToolRound(content: "", calls: [
            ToolCallRecord(id: "a", name: "n", arguments: ""),
            ToolCallRecord(id: "b", name: "n", arguments: #"{"x":"#, startedAt: Date()),
        ])]
        let sent = messages([reply], options())
        try #require(sent.count == 3)
        let calls = try #require(sent[0]["tool_calls"] as? [[String: Any]])
        #expect(calls.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String } == ["{}", "{}"])
        #expect(sent[1]["content"] as? String == ToolResultText.notRun)
        #expect(sent[2]["content"] as? String == ToolResultText.interrupted)
    }

    @Test func withoutToolsRoundsAreFlattened() throws {
        var request = options()
        request.omitsTools = true
        let history = [Message(role: .user, content: "hi"), replyWithRound()]
        for o in [request, options(tools: nil), options(tools: [])] {
            let sent = messages(history, o)
            try #require(sent.map { $0["role"] as? String } == ["user", "assistant"])
            #expect(sent[1]["tool_calls"] == nil)
            #expect(sent[1]["content"] as? String == """
            [Earlier tool call: srv.echo({"text":"hi"})]

            [Result]
            hi

            Done.
            """)
        }
    }

    @Test func toolsGoLastAndKeysAreSorted() throws {
        let o = options()
        let body = ChatClient.buildRequestBody(messages: [replyWithRound()], options: o)
        let first = try ChatClient.encodeBody(body, options: o)
        let second = try ChatClient.encodeBody(ChatClient.buildRequestBody(messages: [replyWithRound()], options: o), options: o)
        // A stable prefix across rounds is what keeps the prompt cache.
        #expect(first == second || String(decoding: first, as: UTF8.self).hasPrefix(#"{"messages""#))
        #expect(String(decoding: first, as: UTF8.self).contains(#""tools":[{"function":{"description":"Echoes.","name":"srv__echo""#))
    }

    @Test func tooLargeMessageNamesToolData() {
        let plain = ChatClient.requestTooLargeMessage(bytes: 20_000_000, limit: 12_000_000)
        let tools = ChatClient.requestTooLargeMessage(bytes: 20_000_000, limit: 12_000_000, carriesToolData: true)
        #expect(plain.contains("remove some"))
        #expect(tools.contains("Images and tool results are sent again"))
        #expect(ChatClient.requestTooLarge(in: tools)?.limit == "11.4 MB")
    }

    @Test func requestSizeGuardCountsToolData() async {
        let client = try! ChatClient(baseURL: "http://127.0.0.1:9/v1", apiKey: nil)
        var o = options()
        o.maxRequestBytes = 1024
        var reply = replyWithRound()
        reply.toolRounds?[0].calls[0].result?.text = String(repeating: "x", count: 4096)
        do {
            for try await _ in client.streamChat(messages: [reply], options: o) {}
            Issue.record("expected the size guard")
        } catch {
            #expect((error as? ParleyError).flatMap { error -> Bool? in
                if case .api(let message) = error { return message.contains("tool results") }
                return nil
            } == true)
        }
    }
}
