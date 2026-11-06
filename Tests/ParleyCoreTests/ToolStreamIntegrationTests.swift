import Foundation
import Testing
@testable import ParleyCore

// ChatClient against tools/mock_server.py: every tool-call shape, the replay that follows it, and
// refusals. The mock validates every request with tool data as strictly as the strictest server.

private let python = "/usr/bin/python3"
private let mockScript = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/mock_server.py")

private func withChatMock(_ flavor: String = "lmstudio", _ body: (String) async throws -> Void) async throws {
    let port = try mcpFreePort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-I", "-u", mockScript.path, String(port), flavor]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        _ = exited.wait(timeout: .now() + 5)
    }
    let base = "http://127.0.0.1:\(port)/v1"
    StreamOptionsSupport.forget(baseURL: URL(string: base)!)
    let probe = try ChatClient(baseURL: base, apiKey: nil)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if (try? await probe.listModels()) != nil { return try await body(base) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw MCPMockFailed(description: "mock server did not start")
}

private func mockJSON(_ base: String, _ path: String) async throws -> [String: Any] {
    let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + path)!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private let echoTool = ChatTool(name: "srv__echo", description: "Echoes.", parameters: .object([
    "type": .string("object"),
    "properties": .object(["text": .object(["type": .string("string")])]),
]))

private func options(_ model: String) -> ChatRequestOptions {
    var o = ChatRequestOptions(model: model)
    o.tools = [echoTool]
    return o
}

private func run(_ base: String, _ messages: [Message], _ options: ChatRequestOptions) async throws -> (StreamAccumulator, [ChatDelta]) {
    let client = try ChatClient(baseURL: base, apiKey: nil)
    var accumulator = StreamAccumulator()
    var deltas: [ChatDelta] = []
    for try await delta in client.streamChat(messages: messages, options: options) {
        accumulator.apply(delta)
        deltas.append(delta)
    }
    accumulator.finish()
    return (accumulator, deltas)
}

/// The reply after one round: what the session would store.
private func reply(_ calls: [ToolCallRecord]) -> Message {
    var message = Message(role: .assistant, content: "")
    var resolved = calls
    for i in resolved.indices {
        resolved[i].result = ToolCallResult(status: .completed, text: "result \(i)")
    }
    message.toolRounds = [ToolRound(content: "", calls: resolved)]
    return message
}

private let userPrompt = #"please tool=srv__echo args={"text":"hello world"}"#

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
struct ToolStreamIntegrationTests {
    @Test func everyShapeThenReplay() async throws {
        try await withChatMock { base in
            for model in ["mock-tools", "mock-tools-llamacpp", "mock-tools-vllm", "mock-tools-ollama", "mock-tools-nonstream", "mock-tools-content"] {
                let user = Message(role: .user, content: userPrompt)
                let (first, deltas) = try await run(base, [user], options(model))
                let calls = first.toolCalls.finalCalls()
                #expect(calls.count == 1, "\(model)")
                #expect(calls.first?.name == "srv__echo", "\(model)")
                #expect(ToolArguments.parse(calls.first?.arguments ?? "") == ["text": .string("hello world")], "\(model)")
                #expect(first.finishReason == "tool_calls", "\(model)")
                #expect(deltas.contains { !$0.toolCalls.isEmpty }, "\(model)")

                // The mock refuses a replay any server would refuse.
                let (second, _) = try await run(base, [user, reply(calls)], options(model))
                #expect(second.content == "tool said: result 0", "\(model)")
                #expect(second.toolCalls.isEmpty, "\(model)")
            }
        }
    }

    @Test func contentAndCallTogether() async throws {
        try await withChatMock { base in
            let (vllm, _) = try await run(base, [Message(role: .user, content: "x")], options("mock-tools-vllm"))
            #expect(vllm.content == "Let me look.")
            #expect(vllm.toolCalls.finalCalls().count == 1)
            let (split, _) = try await run(base, [Message(role: .user, content: "x")], options("mock-tools-content"))
            #expect(split.content == "Let me check that for you.")
            #expect(split.toolCalls.finalCalls().count == 1)
        }
    }

    @Test func parallelCalls() async throws {
        try await withChatMock { base in
            var request = options("mock-tools-parallel")
            request.tools = [echoTool, ChatTool(name: "srv__add", parameters: .object(["type": .string("object")]))]
            let user = Message(role: .user, content: #"tool=srv__echo args={"text":"long enough to split"}"#)
            let (first, _) = try await run(base, [user], request)
            let calls = first.toolCalls.finalCalls()
            #expect(calls.map(\.name) == ["srv__echo", "srv__add"])
            #expect(calls.map(\.arguments) == [#"{"text":"long enough to split"}"#, #"{"n":2}"#])
            let (second, _) = try await run(base, [user, reply(calls)], request)
            #expect(second.content == "tool said: result 1")
        }
    }

    @Test func malformedArgumentsReachTheParserAndReplayAsAnObject() async throws {
        try await withChatMock { base in
            let user = Message(role: .user, content: "x")
            let (first, _) = try await run(base, [user], options("mock-tools-malformed"))
            let calls = first.toolCalls.finalCalls()
            try #require(calls.map(\.arguments) == [#"{"a":"#])
            #expect(ToolArguments.parse(calls[0].arguments) == nil)
            _ = try await run(base, [user, reply(calls)], options("mock-tools-malformed"))
        }
    }

    @Test func blankAndRepeatedIDsReplayValidly() async throws {
        try await withChatMock { base in
            let user = Message(role: .user, content: "x")
            let (first, _) = try await run(base, [user], options("mock-tools-noid"))
            let calls = first.toolCalls.finalCalls()
            #expect(calls.count == 3)
            #expect(Set(calls.map(\.id)).count == 3)
            _ = try await run(base, [user, reply(calls)], options("mock-tools-noid"))
        }
    }

    @Test func lengthEndsInsideACall() async throws {
        try await withChatMock { base in
            let (first, _) = try await run(base, [Message(role: .user, content: "x")], options("mock-tools-length"))
            #expect(first.finishReason == "length")
        }
    }

    @Test func llamaCppAndVLLMFlavorsToo() async throws {
        for flavor in ["llamacpp", "vllm", "ollama", "plain"] {
            try await withChatMock(flavor) { base in
                let (first, _) = try await run(base, [Message(role: .user, content: userPrompt)], options("mock-tools"))
                #expect(first.toolCalls.finalCalls().count == 1, "\(flavor)")
            }
        }
    }

    @Test func strataNativeShape() async throws {
        try await withChatMock("strata-share") { base in
            let user = Message(role: .user, content: userPrompt)
            var request = options("strata-tools")
            request.serverKind = .strata
            let (first, _) = try await run(base, [user], request)
            let calls = first.toolCalls.finalCalls()
            #expect(ToolArguments.parse(calls.first?.arguments ?? "") == ["text": .string("hello world")])
            #expect(first.usage?.promptTokens == 50)
            let (second, _) = try await run(base, [user, reply(calls)], request)
            #expect(second.content == "tool said: result 0")
        }
    }

    @Test func strataRuntimeIsRecognized() async throws {
        try await withChatMock("strata-runtime") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "strata-qwen")
            #expect(info.serverKind == .strata)
            #expect(info.ignoresTools)
            #expect(info.maxRequestBytes == strataRuntimeBodyLimit)
        }
        try await withChatMock("strata-share") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "strata-qwen")
            #expect(!info.ignoresTools)
        }
    }

    @Test func refusalIsRetriedWithoutToolsAndFlattened() async throws {
        try await withChatMock { base in
            let prior = Message(role: .user, content: "x")
            var round = reply([ToolCallRecord(id: "a", name: "srv__echo", arguments: "{}", serverName: "srv", toolName: "echo")])
            round.content = "ok"
            for (model, kind) in [("mock-tools-refuse-ollama", ToolsRefusal.Kind.unsupported),
                                  ("mock-tools-refuse-llamacpp", .unsupported),
                                  ("mock-tools-refuse-vllm", .unsupported),
                                  ("mock-tools-refuse-schema", .definitions)] {
                let (accumulator, deltas) = try await run(base, [prior, round, Message(role: .user, content: "y")], options(model))
                let refusal = deltas.compactMap(\.toolsRejected).first
                #expect(refusal?.kind == kind, "\(model)")
                #expect(refusal?.message.isEmpty == false, "\(model)")
                #expect(accumulator.content == "no tools here", "\(model)")
                let sent = try await mockJSON(base, "/mock/last-messages")
                #expect(sent["tools"] is NSNull, "\(model)")
                let messages = try #require(sent["messages"] as? [[String: Any]])
                #expect(messages.allSatisfy { $0["tool_calls"] == nil && $0["role"] as? String != "tool" }, "\(model)")
            }
        }
    }

    @Test func refusedTwiceThrowsTheFirstAnswer() async throws {
        try await withChatMock { base in
            do {
                _ = try await run(base, [Message(role: .user, content: "x")], options("mock-tools-refuse-always"))
                Issue.record("expected the refusal")
            } catch let error as ParleyError {
                guard case .http(let status, let body) = error else {
                    Issue.record("unexpected \(error)")
                    return
                }
                #expect(status == 400)
                #expect(body.contains("does not support tools"))
            }
        }
    }

    @Test func refusalCombinesWithTheOtherRetries() async throws {
        try await withChatMock("openai-strict") { base in
            var request = options("mock-tools-refuse-ollama")
            request.disablesThinking = true
            let (accumulator, deltas) = try await run(base, [Message(role: .user, content: "x")], request)
            #expect(deltas.compactMap(\.toolsRejected).count == 1)
            #expect(deltas.contains { $0.thinkingOffRejected })
            #expect(accumulator.content == "no tools here")
        }
    }

    @Test func noToolsMeansNoToolsKeyOnTheWire() async throws {
        for flavor in ["lmstudio", "llamacpp", "vllm", "ollama", "plain"] {
            try await withChatMock(flavor) { base in
                _ = try await run(base, [Message(role: .user, content: "x")], ChatRequestOptions(model: "mock-plain"))
                let sent = try await mockJSON(base, "/mock/last-request")
                #expect(sent["tools"] == nil, "\(flavor)")
                #expect(sent["tool_choice"] == nil, "\(flavor)")
                let counters = try await mockJSON(base, "/mock/requests")
                #expect(counters["requests_with_tools"] as? Int == 0, "\(flavor)")
            }
        }
    }
}

@Suite struct ToolsRefusalTests {
    @Test func unsupported() {
        for (status, body) in [
            (400, "qwen3 does not support tools"),
            (400, #"{"error":{"message":"registry.ollama.ai/library/x does not support tools","type":"invalid_request_error"}}"#),
            (500, #"{"error":{"code":500,"message":"tools param requires --jinja flag"}}"#),
            (400, #""auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set"#),
            (400, "Unable to generate parser for this template. Automatic parser generation failed: x"),
            (404, "This model does not support tool use"),
            (400, "Tool use is not supported for this model."),
            (400, "tools is not supported in this model"),
            (422, "tools are not supported"),
            (400, "Function calling is not enabled for models/x"),
            (400, "Unrecognized request argument supplied: tools"),
            (400, "Unknown parameter: 'tools'."),
            (400, #"{"error":{"message":"nope","param":"tools"}}"#),
            (501, "this server doesn't support tools"),
        ] {
            #expect(ToolsSupport.refusal(status: status, body: body) == .unsupported, "\(body)")
        }
    }

    @Test func definitions() {
        #expect(ToolsSupport.refusal(status: 500, body: "Failed to parse tools: bad") == .definitions)
        #expect(ToolsSupport.refusal(status: 400, body: "JSON schema error at /properties/x: schema must be an object") == .definitions)
    }

    @Test func notARefusal() {
        #expect(ToolsSupport.refusal(status: 400, body: "This model's maximum context length is 8192 tokens, tools are not supported") == nil)
        #expect(ToolsSupport.refusal(status: 400, body: "request exceeds the context window: tools are not supported") == nil)
        #expect(ToolsSupport.refusal(status: 400, body: "mock bad request") == nil)
        #expect(ToolsSupport.refusal(status: 401, body: "does not support tools") == nil)
        #expect(ToolsSupport.refusal(status: 503, body: "does not support tools") == nil)
    }

    @Test func messageIsTheServersOwnWords() {
        #expect(ToolsSupport.message(body: #"{"error":{"message":"no tools"}}"#) == "no tools")
        #expect(ToolsSupport.message(body: "plain") == "plain")
    }
}
