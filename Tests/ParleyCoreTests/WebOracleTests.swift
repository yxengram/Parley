import Foundation
import Testing
@testable import ParleyCore

// Test vectors for Parley Web's JavaScript ports (Web/src/chat.js and context.js), written by the
// app's own code so the ports are checked against it, not against hand-written expectations.
// Runs only with PARLEY_WEB_VECTORS set to a folder:
//   PARLEY_WEB_VECTORS=Web/tests/vectors swift test --filter writeWebVectors
// The files are committed; tools/test_web.sh compares the JS output with them.

private let vectorFolder = ProcessInfo.processInfo.environment["PARLEY_WEB_VECTORS"]

private func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(seconds)) }

private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

private func encoder() -> JSONEncoder {
    let e = ConversationFile.makeEncoder(pretty: true)
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}

/// Encodes a Codable value to a JSON object (for embedding in a vector file).
private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: try encoder().encode(value), options: [.fragmentsAllowed])
}

private func write(_ name: String, _ value: Any) throws {
    guard let folder = vectorFolder else { return }
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url)
}

private func usageObject(_ usage: TokenUsage?) -> Any {
    guard let usage else { return NSNull() }
    var o: [String: Any] = [:]
    if let v = usage.promptTokens { o["promptTokens"] = v }
    if let v = usage.completionTokens { o["completionTokens"] = v }
    if let v = usage.totalTokens { o["totalTokens"] = v }
    if let v = usage.reasoningTokens { o["reasoningTokens"] = v }
    if let v = usage.cachedPromptTokens { o["cachedPromptTokens"] = v }
    return o
}

private func deltaObject(_ delta: ChatDelta?) -> Any {
    guard let delta else { return NSNull() }
    var o: [String: Any] = [:]
    if let v = delta.content { o["content"] = v }
    if let v = delta.reasoning { o["reasoning"] = v }
    if delta.usage != nil { o["usage"] = usageObject(delta.usage) }
    if let v = delta.finishReason { o["finishReason"] = v }
    if let t = delta.timings {
        var timings: [String: Any] = [:]
        if let v = t.promptTokens { timings["promptTokens"] = v }
        if let v = t.promptMilliseconds { timings["promptMilliseconds"] = v }
        if let v = t.cachedTokens { timings["cachedTokens"] = v }
        if let v = t.predictedTokens { timings["predictedTokens"] = v }
        if let v = t.predictedMilliseconds { timings["predictedMilliseconds"] = v }
        if let v = t.predictedPerSecond { timings["predictedPerSecond"] = v }
        if let v = t.promptPerSecond { timings["promptPerSecond"] = v }
        o["timings"] = timings
    }
    if let p = delta.promptProgress {
        var progress: [String: Any] = ["total": p.total, "cached": p.cached, "processed": p.processed]
        if let ms = p.milliseconds { progress["milliseconds"] = ms }
        o["promptProgress"] = progress
    }
    return o
}

// MARK: Histories used by several vector files

private func png() -> ParleyCore.Attachment {
    ParleyCore.Attachment(id: id(900), kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
}

private func histories() -> [(name: String, messages: [Message])] {
    var reasoned = Message(id: id(3), role: .assistant, content: "Hello!", reasoning: "Think first.", createdAt: at(3))
    reasoned.usage = TokenUsage(promptTokens: 120, completionTokens: 40, totalTokens: 160, reasoningTokens: 12)
    var counted = Message(id: id(5), role: .assistant, content: "Counted reply", createdAt: at(5))
    counted.usage = TokenUsage(promptTokens: 300, completionTokens: 20)
    var thinkingOnly = Message(id: id(8), role: .assistant, content: "Answer", reasoning: String(repeating: "deliberate ", count: 40), createdAt: at(8))
    thinkingOnly.usage = TokenUsage(promptTokens: 50, completionTokens: 200)
    let failed = Message(id: id(6), role: .assistant, content: "", createdAt: at(6), isComplete: false, error: "HTTP 500: boom")
    let text = ParleyCore.Attachment(id: id(901), kind: .text, filename: "notes \"a\".txt", mimeType: "text/plain", text: "line one\nline two")
    return [
        ("plain", [Message(id: id(1), role: .user, content: "Hi", createdAt: at(1)), reasoned,
                   Message(id: id(4), role: .user, content: "Next question", createdAt: at(4))]),
        ("attachments", [Message(id: id(1), role: .user, content: "Look", attachments: [png(), text], createdAt: at(1)),
                         counted, Message(id: id(7), role: .user, content: "", attachments: [text], createdAt: at(7))]),
        ("failedAndSystem", [Message(id: id(1), role: .user, content: "Q", createdAt: at(1)), failed,
                             Message(id: id(2), role: .system, content: "  ", createdAt: at(2)),
                             Message(id: id(9), role: .system, content: "Be terse.", createdAt: at(9)),
                             Message(id: id(4), role: .user, content: "Again", createdAt: at(4))]),
        ("chinese", [Message(id: id(1), role: .user, content: "你好，请用三句话介绍杭州。", createdAt: at(1)), thinkingOnly,
                     Message(id: id(4), role: .user, content: "再说说西湖的历史吧", createdAt: at(4))]),
    ]
}

@Suite(.enabled(if: vectorFolder != nil)) struct WebOracleTests {
    @Test func writeWebVectors() throws {
        try writeSSE()
        try writeChunks()
        try writeAccumulator()
        try writeRequests()
        try writeUsage()
        try writeCompaction()
        try writeErrors()
    }

    private func writeSSE() throws {
        let cases: [[String]] = [
            ["data: {\"a\":1}", "", "data: {\"b\":2}", ""],
            ["data:{\"no\":\"space\"}", ""],
            [": comment", "id: 7", "retry: 1000", "data: {\"x\":1}", ""],
            ["data: {\"split\":", "data: true}", ""],
            ["data: [DONE]", ""],
            ["event: error", "data: {\"message\":\"overloaded\"}", ""],
            ["error: {\"message\":\"llama failed\"}", ""],
            ["{\"error\":{\"message\":\"bare\"}}", ""],
            ["data: partial without end"],
            ["data: {\"c\":1}", "data: {\"d\":2}", ""],
        ]
        var out: [[String: Any]] = []
        for lines in cases {
            var decoder = SSEDecoder()
            var payloads: [String] = []
            for line in lines { payloads += decoder.feed(line: line) }
            payloads += decoder.finish()
            out.append(["lines": lines, "payloads": payloads])
        }
        try write("sse.json", out)
    }

    private func writeChunks() throws {
        let payloads = [
            #"{"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#,
            #"{"choices":[{"delta":{"reasoning":"also think"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"completion_tokens_details":{"reasoning_tokens":2},"prompt_tokens_details":{"cached_tokens":4}}}"#,
            #"{"choices":[{"delta":{"content":"x"},"finish_reason":"length"}],"timings":{"prompt_n":12,"prompt_ms":30.5,"predicted_n":40,"predicted_ms":800,"predicted_per_second":50,"prompt_per_second":393.4}}"#,
            #"{"choices":[{"delta":{}}],"prompt_progress":{"total":1000,"cache":200,"processed":500,"time_ms":120}}"#,
            #"{"error":{"message":"model not found"}}"#,
            #"{"error":"plain string error"}"#,
            "[DONE]",
            "not json",
            #"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"message":{"content":"non-stream style"}}]}"#,
        ]
        var out: [[String: Any]] = []
        for payload in payloads {
            do {
                out.append(["payload": payload, "delta": deltaObject(try ChunkParser.parse(payload))])
            } catch {
                out.append(["payload": payload, "error": SystemErrorText.english(error)])
            }
        }
        try write("chunks.json", out)
    }

    private func writeAccumulator() throws {
        let cases: [[[String: String]]] = [
            [["content": "Hello"], ["content": " world"]],
            [["reasoning": "Let me think."], ["content": "Answer."]],
            [["content": "<think>plan"], ["content": " more</think>"], ["content": "Final"]],
            [["content": "<thi"], ["content": "nk>x</th"], ["content": "ink>y"]],
            [["content": "No tags here"]],
            [["content": "Before <think>inside</think> after"]],
            [["content": "<think>never closed"]],
            [["content": "\n\n<think>\nlead</think>\n\nbody"]],
            [["reasoning": "r1"], ["content": "<think>r2</think>c"]],
            [["content": "plan</think>answer"]],
        ]
        var out: [[String: Any]] = []
        for deltas in cases {
            var accumulator = StreamAccumulator()
            let now = at(0)
            for (i, d) in deltas.enumerated() {
                accumulator.apply(ChatDelta(content: d["content"], reasoning: d["reasoning"]), now: now.addingTimeInterval(Double(i)))
            }
            accumulator.finish(now: now.addingTimeInterval(Double(deltas.count)))
            out.append(["deltas": deltas, "content": accumulator.content, "reasoning": accumulator.reasoning])
        }
        try write("accumulator.json", out)
    }

    private func writeRequests() throws {
        struct Variant { let name: String; let options: ChatRequestOptions; let includeUsage: Bool; let json: [String: Any] }
        func options(_ build: (inout ChatRequestOptions) -> Void) -> ChatRequestOptions {
            var o = ChatRequestOptions(model: "m")
            build(&o)
            return o
        }
        let variants: [Variant] = [
            Variant(name: "bare", options: options { _ in }, includeUsage: false, json: ["model": "m"]),
            Variant(name: "full", options: options {
                $0.systemPrompt = "You are kind."; $0.temperature = 0.7; $0.maxTokens = 512; $0.reasoningEffort = .high
            }, includeUsage: true, json: ["model": "m", "systemPrompt": "You are kind.", "temperature": 0.7, "maxTokens": 512,
                                          "reasoningEffort": "high", "includeUsage": true]),
            Variant(name: "summary", options: options {
                $0.systemPrompt = "Sys"; $0.historySummary = Compaction.block("They said hi.")
            }, includeUsage: true, json: ["model": "m", "systemPrompt": "Sys", "historySummary": Compaction.block("They said hi."),
                                          "includeUsage": true]),
            Variant(name: "summaryNoPrompt", options: options { $0.historySummary = Compaction.block("Only summary.") },
                    includeUsage: false, json: ["model": "m", "historySummary": Compaction.block("Only summary.")]),
        ] + [nil, .lmStudio, .llamaCpp, .vLLM, .ollama, .strata, .hosted].map { (kind: InferenceServerKind?) in
            Variant(name: "none-\(kind?.rawValue ?? "unknown")", options: options {
                $0.disablesThinking = true; $0.serverKind = kind; $0.reasoningEffort = .low
            }, includeUsage: true, json: ["model": "m", "disablesThinking": true, "serverKind": kind?.rawValue ?? NSNull(),
                                          "reasoningEffort": "low", "includeUsage": true])
        } + [Variant(name: "none-omitted", options: options {
                $0.disablesThinking = true; $0.serverKind = .lmStudio; $0.omitsThinkingOff = true
            }, includeUsage: false, json: ["model": "m", "disablesThinking": true, "serverKind": "lmStudio", "omitsThinkingOff": true])]
        var out: [[String: Any]] = []
        for history in histories() {
            for variant in variants {
                let body = ChatClient.buildRequestBody(messages: history.messages, options: variant.options, includeUsage: variant.includeUsage)
                let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                out.append(["history": history.name, "messages": try object(history.messages), "options": variant.json,
                            "variant": variant.name, "body": try JSONSerialization.jsonObject(with: data)])
            }
        }
        try write("requests.json", out)
    }

    private func writeUsage() throws {
        let texts = ["", "hello", "Hello, world! How are you today?", "你好世界", "混合 text 和中文，还有 emoji 🎉",
                     String(repeating: "word ", count: 100), "日本語のテキスト", "한국어 문장"]
        var estimates: [[String: Any]] = []
        for text in texts { estimates.append(["text": text, "tokens": ContextBudget.estimateTokens(text)]) }
        var messages: [[String: Any]] = []
        for history in histories() {
            for message in history.messages {
                messages.append(["message": try object(message), "tokens": ContextBudget.estimateTokens(message: message)])
            }
        }
        var usages: [[String: Any]] = []
        for history in histories() {
            for prompt in ["", "System prompt here."] {
                for anchorsFrom in [0, 1, 2] {
                    let u = ContextBudget.usage(messages: history.messages, systemPrompt: prompt, toolDefinitionTokens: 0, anchorsFrom: anchorsFrom)
                    usages.append(["history": history.name, "messages": try object(history.messages), "systemPrompt": prompt,
                                   "anchorsFrom": anchorsFrom, "tokens": u.tokens, "isEstimated": u.isEstimated])
                }
            }
            // In flight: the last user message's reply is streaming.
            var inFlight = history.messages
            inFlight.append(Message(id: id(99), role: .assistant, content: "partial", createdAt: at(99), isComplete: false))
            let u = ContextBudget.usage(messages: inFlight, systemPrompt: "S", inFlightID: id(99), liveCompletionTokens: 33, liveIsEstimated: true)
            usages.append(["history": history.name + "+inFlight", "messages": try object(inFlight), "systemPrompt": "S",
                           "inFlightID": id(99).uuidString, "liveCompletionTokens": 33, "liveIsEstimated": true,
                           "anchorsFrom": 0, "tokens": u.tokens, "isEstimated": u.isEstimated])
        }
        let limits: [[String: Any]] = [
            ["manual": 8192, "learned": NSNull(), "loaded": NSNull(), "max": NSNull()],
            ["manual": 8192, "learned": 4096, "loaded": NSNull(), "max": NSNull()],
            ["manual": NSNull(), "learned": 4096, "loaded": NSNull(), "max": 32768],
            ["manual": NSNull(), "learned": NSNull(), "loaded": NSNull(), "max": 32768],
            ["manual": 8192, "learned": NSNull(), "loaded": 16384, "max": 32768],
            ["manual": NSNull(), "learned": NSNull(), "loaded": NSNull(), "max": NSNull()],
        ].map { row in
            var info = ModelContextInfo(model: "m")
            info.loadedContextLength = row["loaded"] as? Int
            info.maxContextLength = row["max"] as? Int
            let limit = ContextBudget.limit(info: info, manual: row["manual"] as? Int, learned: row["learned"] as? Int)
            var out = row
            out["limit"] = limit.map { ["tokens": $0.tokens, "source": "\($0.source)"] } ?? NSNull()
            return out
        }
        try write("usage.json", ["estimates": estimates, "messages": messages, "usage": usages, "limits": limits])
    }

    private func writeCompaction() throws {
        func turns(_ n: Int, size: Int) -> [Message] {
            (0..<n).flatMap { i in
                [Message(id: id(100 + 2 * i), role: .user, content: "question \(i) " + String(repeating: "x", count: size), createdAt: at(100 + 2 * i)),
                 Message(id: id(101 + 2 * i), role: .assistant, content: "answer \(i) " + String(repeating: "y", count: size), createdAt: at(101 + 2 * i))]
            }
        }
        // One message list per scenario, then every combination of the other inputs.
        var boundaries: [[String: Any]] = []
        for (n, size) in [(1, 40), (3, 40), (6, 40), (6, 400)] {
            let messages = turns(n, size: size)
            var cases: [[String: Any]] = []
            for limit in [nil, 10, 400, 4000] as [Int?] {
                for current in [nil, 1, 3] as [Int?] {
                    for before in [nil, messages.count - 1] as [Int?] {
                        let b = Compaction.boundary(in: messages, current: current, limitTokens: limit, before: before)
                        cases.append(["current": current.map { $0 as Any } ?? NSNull(), "limitTokens": limit.map { $0 as Any } ?? NSNull(),
                                      "before": before.map { $0 as Any } ?? NSNull(), "boundary": b.map { $0 as Any } ?? NSNull()])
                    }
                }
            }
            boundaries.append(["messages": try object(messages), "cases": cases])
        }
        let image = Message(id: id(300), role: .user, content: "look", attachments: [png()], createdAt: at(300))
        var thought = Message(id: id(301), role: .assistant, content: "seen", reasoning: "secret", createdAt: at(301))
        thought.usage = TokenUsage(promptTokens: 9, completionTokens: 1)
        let failed = Message(id: id(302), role: .assistant, content: "", createdAt: at(302), isComplete: false, error: "x")
        let requestCases: [(String?, [Message])] = [
            (nil, [Message(id: id(310), role: .user, content: "a", createdAt: at(310)), Message(id: id(311), role: .assistant, content: "b", createdAt: at(311))]),
            ("Before: hello.", [image, thought, failed, Message(id: id(303), role: .user, content: "and then", createdAt: at(303))]),
            ("So far.", [Message(id: id(320), role: .assistant, content: "a2", createdAt: at(320)), Message(id: id(321), role: .user, content: "u3", createdAt: at(321)),
                         Message(id: id(322), role: .assistant, content: "a3", createdAt: at(322))]),
            (nil, [Message(id: id(330), role: .user, content: "u1", createdAt: at(330)), failed, Message(id: id(331), role: .user, content: "u2", createdAt: at(331))]),
        ]
        var requests: [[String: Any]] = []
        for (summary, messages) in requestCases {
            let out = Compaction.requestMessages(previousSummary: summary, messages: messages)
            requests.append(["previousSummary": summary ?? NSNull(), "messages": try object(messages),
                             "result": out.map { ["role": $0.role.rawValue, "content": $0.content, "attachments": $0.attachments.count] }])
        }
        let chunkInput = (0..<10).map { Message(id: id(400 + $0), role: .user, content: "message \($0) " + String(repeating: "z", count: 400), createdAt: at(400 + $0)) }
        let chunks = Compaction.chunks(chunkInput, budgetTokens: 250).map { $0.map(\.id.uuidString) }

        // effectiveHistory, truncate and fork on a compacted conversation.
        let messages = [Message(id: id(500), role: .user, content: "u0", createdAt: at(500)), Message(id: id(501), role: .assistant, content: "a1", createdAt: at(501)),
                        Message(id: id(502), role: .user, content: "u2", createdAt: at(502)), Message(id: id(503), role: .assistant, content: "a3", createdAt: at(503)),
                        Message(id: id(504), role: .user, content: "u4", createdAt: at(504)), Message(id: id(505), role: .assistant, content: "a5", createdAt: at(505))]
        let conversation = Conversation(id: id(550), title: "T", createdAt: at(0), updatedAt: at(1), messages: messages,
                                        compaction: ConversationCompaction(summary: "They talked.", throughMessageID: id(503), countsStaleThroughID: id(505),
                                                                           createdAt: at(510), model: "m", messageCount: 4))
        var effective: [[String: Any]] = []
        for keep in [5, 4, 3, 2] {
            var c = conversation
            c.truncate(keepingThrough: keep)
            let e = c.effectiveHistory
            effective.append(["truncatedThrough": keep, "conversation": try object(c),
                              "messageIDs": e.messages.map(\.id.uuidString), "summaryBlock": e.summaryBlock ?? NSNull(),
                              "anchorsFrom": e.anchorsFrom, "coveredCount": e.coveredCount,
                              "systemText": e.systemText(prompt: "Sys")])
        }
        var forks: [[String: Any]] = []
        for through in [5, 4, 3, 2] {
            let f = conversation.forked(through: through)
            forks.append(["through": through, "messageIDs": f.messages.map(\.id.uuidString),
                          "compaction": f.compaction.map { try? object($0) } as Any? ?? NSNull()])
        }
        let dueCases: [(Int, Int?, Int)] = [(800, 1000, 80), (799, 1000, 80), (800, 1001, 80), (500, nil, 80), (950, 1000, 95)]
        let due: [[String: Any]] = dueCases.map {
            ["tokens": $0.0, "limit": $0.1.map { $0 as Any } ?? NSNull(), "percent": $0.2,
             "due": Compaction.isDue(usage: ContextUsage(tokens: $0.0, isEstimated: true),
                                     limit: $0.1.map { ContextLimit(tokens: $0, source: .manual) }, thresholdPercent: $0.2)]
        }
        try write("compaction.json", [
            "instruction": Compaction.instruction, "block": Compaction.block("  Summary text.  "),
            "constants": ["defaultThresholdPercent": Compaction.defaultThresholdPercent, "thresholdMin": Compaction.thresholdRange.lowerBound,
                          "thresholdMax": Compaction.thresholdRange.upperBound, "summaryMaxTokens": Compaction.summaryMaxTokens, "keptShare": Compaction.keptShare],
            "boundaries": boundaries, "requestMessages": requests,
            "chunks": ["messages": try object(chunkInput), "budgetTokens": 250, "result": chunks],
            "conversation": try object(conversation), "effective": effective, "forks": forks, "due": due,
        ])
    }

    private func writeErrors() throws {
        let texts = [
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens.",
            "the request exceeds the available context size, try increasing it (n_ctx: 4096)",
            "Trying to keep the first 5000 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens",
            "prompt is too long: 200000 tokens > 131072 maximum",
            "HTTP 500: boom",
            "",
        ]
        try write("errors.json", texts.map { ["text": $0, "contextLength": ContextBudget.contextLength(fromError: $0).map { $0 as Any } ?? NSNull()] })
    }
}
