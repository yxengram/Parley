import Foundation
import Testing
@testable import ParleyCore

// Token speed, context-length discovery and context usage: parsers for each server's real
// response shape, precedence, estimate and speed math, the stream_options fallback, the LM Studio
// reload flow, and backward-compatible decoding of files written before these fields existed.
// Network tests only ever talk to tools/mock_server.py on 127.0.0.1.

private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

private func t(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 2_000_000 + seconds) }

// MARK: - Parsers

@Suite struct ModelInfoParserTests {
    // Live shape from LM Studio 0.4 (GET /api/v1/models), trimmed.
    private let lmStudioV1 = #"""
    {"models":[
      {"type":"llm","publisher":"jangq","key":"gemma-4-31b-jang_4m-crack","display_name":"Gemma 4 31B",
       "architecture":"gemma3","quantization":{"name":"4bit","bits_per_weight":4},"size_bytes":18000000000,
       "params_string":"31B","max_context_length":262144,"format":"mlx",
       "loaded_instances":[{"id":"gemma-4-31b-jang_4m-crack","config":{"context_length":20224,"eval_batch_size":2048,
         "physical_batch_size":512,"parallel":4,"flash_attention":true},"remaining_ttl_seconds":7200}],
       "capabilities":{"vision":true,"trained_for_tool_use":true}},
      {"type":"llm","publisher":"qwen","key":"qwen3-14b","display_name":"Qwen3 14B","max_context_length":40960,
       "loaded_instances":[],"capabilities":{}},
      {"type":"embedding","publisher":"nomic","key":"text-embedding-nomic","max_context_length":2048,"loaded_instances":[]},
      {"type":"decision","publisher":"x","key":"router","max_context_length":null,"loaded_instances":[]}
    ]}
    """#

    @Test func lmStudioV1Loaded() throws {
        let info = try #require(ChatClient.parseLMStudioV1(try json(lmStudioV1), model: "gemma-4-31b-jang_4m-crack"))
        #expect(info.serverKind == .lmStudio)
        #expect(info.loadedContextLength == 20224)
        #expect(info.maxContextLength == 262144)
        #expect(info.isLoaded == true)
        #expect(info.canSetContextLength)
        #expect(info.modelKey == "gemma-4-31b-jang_4m-crack")
        #expect(info.instanceIDs == ["gemma-4-31b-jang_4m-crack"])
    }

    @Test func lmStudioV1NotLoadedAndOthers() throws {
        let root = try json(lmStudioV1)
        let qwen = try #require(ChatClient.parseLMStudioV1(root, model: "qwen3-14b"))
        #expect(qwen.loadedContextLength == nil)
        #expect(qwen.maxContextLength == 40960)
        #expect(qwen.isLoaded == false)
        #expect(qwen.canSetContextLength)
        #expect(qwen.instanceIDs.isEmpty)
        // Embedding models cannot be reloaded for chat; null max is unknown.
        #expect(ChatClient.parseLMStudioV1(root, model: "text-embedding-nomic")?.canSetContextLength == false)
        #expect(ChatClient.parseLMStudioV1(root, model: "router")?.maxContextLength == nil)
        // LM Studio, but the model is not listed: kind known, nothing else.
        let missing = try #require(ChatClient.parseLMStudioV1(root, model: "nope"))
        #expect(missing.serverKind == .lmStudio && missing.loadedContextLength == nil && !missing.canSetContextLength)
    }

    @Test func lmStudioV1MatchesInstanceID() throws {
        let root = try json(#"{"models":[{"type":"llm","key":"m","max_context_length":8000,"loaded_instances":[{"id":"m","config":{"context_length":2000}},{"id":"m:2","config":{"context_length":4000}}]}]}"#)
        let info = try #require(ChatClient.parseLMStudioV1(root, model: "m:2"))
        #expect(info.modelKey == "m")
        #expect(info.loadedContextLength == 4000)
        #expect(info.instanceIDs == ["m", "m:2"])
    }

    @Test func lmStudioUnknownEndpointBodyIsRejected() throws {
        let error = try json(#"{"error":"Unexpected endpoint or method. (GET /api/v1/models)"}"#)
        #expect(ChatClient.parseLMStudioV1(error, model: "m") == nil)
        #expect(ChatClient.parseLMStudioV0(error, model: "m") == nil)
        #expect(ChatClient.parseLlamaCppProps(error) == nil)
        #expect(ChatClient.parseOllamaPS(error, model: "m") == nil)
        // Other servers' lists are not mistaken for LM Studio's.
        #expect(ChatClient.parseLMStudioV1(try json(#"{"models":[{"name":"llama3:latest","model":"llama3:latest"}]}"#), model: "m") == nil)
    }

    @Test func lmStudioV0() throws {
        let root = try json(#"""
        {"object":"list","data":[
          {"id":"gemma-4-31b-jang_4m-crack","object":"model","type":"vlm","publisher":"jangq","arch":"gemma3",
           "compatibility_type":"mlx","quantization":"4bit","state":"loaded","max_context_length":262144,
           "loaded_context_length":20224,"capabilities":["tool_use"]},
          {"id":"qwen3-14b","object":"model","type":"llm","state":"not-loaded","max_context_length":40960}
        ]}
        """#)
        let loaded = try #require(ChatClient.parseLMStudioV0(root, model: "gemma-4-31b-jang_4m-crack"))
        #expect(loaded.loadedContextLength == 20224)
        #expect(loaded.maxContextLength == 262144)
        #expect(loaded.isLoaded == true)
        #expect(!loaded.canSetContextLength)   // no REST load before 0.4
        let idle = try #require(ChatClient.parseLMStudioV0(root, model: "qwen3-14b"))
        #expect(idle.loadedContextLength == nil && idle.isLoaded == false && idle.maxContextLength == 40960)
        // An OpenAI list has no "state": not LM Studio.
        #expect(ChatClient.parseLMStudioV0(try json(#"{"object":"list","data":[{"id":"x","object":"model"}]}"#), model: "x") == nil)
    }

    @Test func llamaCppProps() throws {
        let root = try json(#"""
        {"default_generation_settings":{"n_ctx":8192,"params":{"temperature":0.8}},"total_slots":4,
         "model_path":"/m/qwen.gguf","modalities":{"vision":false},"build_info":"b6000","is_sleeping":false}
        """#)
        let info = try #require(ChatClient.parseLlamaCppProps(root))
        #expect(info.serverKind == .llamaCpp)
        #expect(info.loadedContextLength == 8192)
        #expect(ChatClient.parseLlamaCppProps(try json(#"{"error":{"code":400,"message":"model name is missing from the request"}}"#)) == nil)
    }

    @Test func ollamaPS() throws {
        let root = try json(#"""
        {"models":[{"name":"llama3.2:latest","model":"llama3.2:latest","size":3000,"digest":"abc",
          "details":{"family":"llama"},"expires_at":"2026-11-03T10:00:00Z","size_vram":3000,"context_length":4096}]}
        """#)
        let info = try #require(ChatClient.parseOllamaPS(root, model: "llama3.2"))
        #expect(info.serverKind == .ollama && info.loadedContextLength == 4096 && info.isLoaded == true)
        let other = try #require(ChatClient.parseOllamaPS(root, model: "qwen3"))
        #expect(other.isLoaded == false && other.loadedContextLength == nil)
    }

    @Test func openAIStyleLists() throws {
        // vLLM
        let vllm = try json(#"{"object":"list","data":[{"id":"Qwen/Qwen3-8B","object":"model","created":1,"owned_by":"vllm","root":"Qwen/Qwen3-8B","parent":null,"max_model_len":32768,"permission":[]}]}"#)
        let v = try #require(ChatClient.parseModelList(vllm, model: "Qwen/Qwen3-8B"))
        #expect(v.serverKind == .vLLM && v.loadedContextLength == 32768 && v.maxContextLength == 32768)

        // llama.cpp (current builds carry meta.n_ctx; older only n_ctx_train)
        let llama = try json(#"{"object":"list","data":[{"id":"qwen.gguf","object":"model","owned_by":"llamacpp","meta":{"vocab_type":2,"n_vocab":151936,"n_ctx":16384,"n_ctx_train":131072,"n_embd":4096}}]}"#)
        let l = try #require(ChatClient.parseModelList(llama, model: "qwen.gguf"))
        #expect(l.serverKind == .llamaCpp && l.loadedContextLength == 16384 && l.maxContextLength == 131072)
        let old = try json(#"{"data":[{"id":"q","owned_by":"llamacpp","meta":{"n_ctx_train":131072}}]}"#)
        #expect(ChatClient.parseModelList(old, model: "q")?.loadedContextLength == nil)
        #expect(ChatClient.parseModelList(old, model: "q")?.maxContextLength == 131072)

        // OpenRouter (context_length + top_provider), Groq (context_window), Mistral (max_context_length)
        let openRouter = try json(#"{"data":[{"id":"a/b","context_length":null,"top_provider":{"context_length":65536,"max_completion_tokens":8192}}]}"#)
        #expect(ChatClient.parseModelList(openRouter, model: "a/b")?.loadedContextLength == 65536)
        #expect(ChatClient.parseModelList(openRouter, model: "a/b")?.serverKind == .hosted)
        let groq = try json(#"{"object":"list","data":[{"id":"llama-3.3-70b","object":"model","owned_by":"Meta","active":true,"context_window":131072}]}"#)
        #expect(ChatClient.parseModelList(groq, model: "llama-3.3-70b")?.loadedContextLength == 131072)
        let mistral = try json(#"{"data":[{"id":"mistral-small","max_context_length":32768}]}"#)
        #expect(ChatClient.parseModelList(mistral, model: "mistral-small")?.maxContextLength == 32768)

        // OpenAI: nothing to learn. LM Studio's OpenAI list only hints at the server kind.
        let openAI = try json(#"{"object":"list","data":[{"id":"gpt-4.1","object":"model","created":1,"owned_by":"system"}]}"#)
        #expect(ChatClient.parseModelList(openAI, model: "gpt-4.1") == nil)
        let lms = try json(#"{"data":[{"id":"qwen3-14b","object":"model","owned_by":"organization_owner"}]}"#)
        #expect(ChatClient.parseModelList(lms, model: "qwen3-14b")?.serverKind == .lmStudio)
        #expect(ChatClient.parseModelList(lms, model: "qwen3-14b")?.loadedContextLength == nil)
    }

    @Test func nativeRootOnlyForV1Paths() throws {
        #expect(try ChatClient(baseURL: "http://100.100.1.2:1234/v1", apiKey: nil).nativeAPIRoot?.absoluteString == "http://100.100.1.2:1234")
        #expect(try ChatClient(baseURL: "http://localhost:1234/v1/", apiKey: nil).nativeAPIRoot?.absoluteString == "http://localhost:1234")
        #expect(try ChatClient(baseURL: "http://host:8080/proxy/v1", apiKey: nil).nativeAPIRoot?.absoluteString == "http://host:8080/proxy")
        #expect(try ChatClient(baseURL: "http://localhost:1234", apiKey: nil).nativeAPIRoot == nil)
        #expect(try ChatClient(baseURL: "http://localhost:1234/v1beta", apiKey: nil).nativeAPIRoot == nil)
        #expect(try ChatClient(baseURL: "https://api.groq.com/openai/v1", apiKey: nil).nativeAPIRoot?.path == "/openai")
    }
}

// MARK: - Precedence and usage

@Suite struct ContextBudgetTests {
    @Test func limitPrecedence() {
        let full = ModelContextInfo(model: "m", loadedContextLength: 20224, maxContextLength: 262144)
        #expect(ContextBudget.limit(info: full, manual: 8000) == ContextLimit(tokens: 20224, source: .server))
        let maxOnly = ModelContextInfo(model: "m", maxContextLength: 262144)
        #expect(ContextBudget.limit(info: maxOnly, manual: 8000) == ContextLimit(tokens: 8000, source: .manual))
        #expect(ContextBudget.limit(info: maxOnly, manual: nil) == ContextLimit(tokens: 262144, source: .serverMaximum))
        #expect(ContextBudget.limit(info: nil, manual: 4096) == ContextLimit(tokens: 4096, source: .manual))
        #expect(ContextBudget.limit(info: nil, manual: nil) == nil)
        #expect(ContextBudget.limit(info: ModelContextInfo(model: "m"), manual: 0) == nil)
    }

    @Test func estimates() {
        #expect(ContextBudget.estimateTokens("") == 0)
        #expect(ContextBudget.estimateTokens("abcd") == 1)
        #expect(ContextBudget.estimateTokens("abcde") == 2)
        #expect(ContextBudget.estimateTokens("你好世界") == 4)
        #expect(ContextBudget.estimateTokens("こんにちは") == 5)
        #expect(ContextBudget.estimateTokens("한국어") == 3)
        #expect(ContextBudget.estimateTokens("杭州 trip") == 2 + 2)   // " trip" is 5 others → 2
        let image = Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([1]))
        let file = Attachment(kind: .text, filename: "abcd", mimeType: "text/plain", text: String(repeating: "x", count: 40))
        let user = Message(role: .user, content: "abcdefgh", attachments: [image, file])
        #expect(ContextBudget.estimateTokens(message: user) == 4 + 2 + 768 + (10 + 1 + 8))
        // Reasoning is not sent back, so it does not count.
        let reply = Message(role: .assistant, content: "abcd", reasoning: String(repeating: "r", count: 400))
        #expect(ContextBudget.estimateTokens(message: reply) == 4 + 1)
    }

    @Test func usageFromLastCountedReply() {
        let messages = [
            Message(role: .user, content: "first"),
            Message(role: .assistant, content: "a", usage: TokenUsage(promptTokens: 100, completionTokens: 20, totalTokens: 120)),
            Message(role: .user, content: "second"),
            Message(role: .assistant, content: "b", usage: TokenUsage(promptTokens: 300, completionTokens: 50, totalTokens: 350)),
        ]
        #expect(ContextBudget.usage(messages: messages, systemPrompt: "ignored, counted by the server")
                == ContextUsage(tokens: 350, isEstimated: false))

        // Reported reasoning tokens are left out (Parley never sends reasoning back).
        var withReasoning = messages
        withReasoning[3].usage?.reasoningTokens = 30
        #expect(ContextBudget.usage(messages: withReasoning, systemPrompt: "").tokens == 320)

        // Only total_tokens.
        let totalOnly = [Message(role: .assistant, content: "x", usage: TokenUsage(totalTokens: 77))]
        #expect(ContextBudget.usage(messages: totalOnly, systemPrompt: "").tokens == 77)
    }

    @Test func usageEstimatesWhatCameAfter() {
        let pending = Message(role: .user, content: "abcdefgh")                 // 4 + 2
        let failed = Message(role: .assistant, content: "", isComplete: false, error: "HTTP 500")
        let messages = [
            Message(role: .assistant, content: "a", usage: TokenUsage(promptTokens: 300, completionTokens: 50)),
            pending, failed,
        ]
        #expect(ContextBudget.usage(messages: messages, systemPrompt: "") == ContextUsage(tokens: 356, isEstimated: true))
    }

    @Test func usageWhileStreaming() {
        let inFlight = Message(role: .assistant, content: "partial", isComplete: false)
        let messages = [
            Message(role: .assistant, content: "a", usage: TokenUsage(promptTokens: 300, completionTokens: 50)),
            Message(role: .user, content: "abcdefgh"),
            inFlight,
        ]
        let exact = ContextBudget.usage(messages: messages, systemPrompt: "", inFlightID: inFlight.id,
                                        liveCompletionTokens: 40, liveIsEstimated: false)
        #expect(exact == ContextUsage(tokens: 350 + 6 + 40, isEstimated: true))   // the new user message is estimated
        // The in-flight reply's own (missing) usage never hides the previous count.
        let first = [Message(role: .user, content: "abcd"), inFlight]
        let live = ContextBudget.usage(messages: first, systemPrompt: "", inFlightID: inFlight.id,
                                       liveCompletionTokens: 12, liveIsEstimated: true)
        #expect(live == ContextUsage(tokens: 5 + 12, isEstimated: true))
    }

    @Test func usageWithoutAnyCount() {
        let messages = [Message(role: .user, content: "帮我规划行程"), Message(role: .assistant, content: "好的")]
        let u = ContextBudget.usage(messages: messages, systemPrompt: "Be brief")   // 4 + 2
        #expect(u == ContextUsage(tokens: (4 + 6) + (4 + 2) + 6, isEstimated: true))
        #expect(ContextBudget.usage(messages: [], systemPrompt: "") == ContextUsage(tokens: 0, isEstimated: false))
        #expect(ContextUsage(tokens: 8192, isEstimated: false).percent(of: 32768) == 25)
    }

    @Test func contextLengthFromOverflowErrors() {
        let llama = #"HTTP 400: {"error":{"code":400,"message":"request (40000 tokens) exceeds the available context size (16384 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":40000,"n_ctx":16384}}"#
        #expect(ContextBudget.contextLength(fromError: llama) == 16384)
        #expect(ContextBudget.contextLength(fromError: "exceeds the available context size (8192 tokens)") == 8192)
        #expect(ContextBudget.contextLength(fromError: "HTTP 400: This model's maximum context length is 32768 tokens. However, you requested 40000 tokens.") == 32768)
        #expect(ContextBudget.contextLength(fromError: "HTTP 503: Model is loading") == nil)
    }
}

// MARK: - Speed

@Suite struct GenerationMeterTests {
    @Test func ignoresEmptyOpeningChunkAndMeasuresRate() {
        var m = GenerationMeter(requestStartedAt: t(0))
        m.record(ChatDelta(content: ""), now: t(0.5))          // role chunk: not a token
        #expect(m.firstTokenAt == nil && m.chunkCount == 0)
        m.record(ChatDelta(reasoning: "Let"), now: t(1.0))
        #expect(m.tokensPerSecond == nil)                       // one token: nothing to measure
        for i in 1...20 { m.record(ChatDelta(content: "x"), now: t(1.0 + Double(i) * 0.1)) }
        #expect(m.chunkCount == 21)
        #expect(m.isEstimated)
        #expect(abs((m.tokensPerSecond ?? 0) - 10) < 1e-9)      // 20 tokens after the first, in 2 s
        #expect(abs((m.timeToFirstToken ?? 0) - 1.0) < 1e-9)
    }

    @Test func serverCountReplacesEstimate() throws {
        var m = GenerationMeter(requestStartedAt: t(0))
        m.record(ChatDelta(content: "Hello"), now: t(0.2))
        m.record(ChatDelta(content: " world, three tokens"), now: t(1.2))
        m.record(ChatDelta(finishReason: "stop"), now: t(1.3))
        m.record(ChatDelta(usage: TokenUsage(promptTokens: 10, completionTokens: 41)), now: t(1.3))
        #expect(!m.isEstimated)
        #expect(m.generatedTokens == 41)
        let stats = try #require(m.finalStats())
        #expect(abs((stats.tokensPerSecond ?? 0) - 40) < 1e-9)  // (41 - 1) / 1 s
        #expect(stats.completionTokens == 41)
        #expect(stats.isEstimated == false)
        #expect(abs((stats.timeToFirstToken ?? 0) - 0.2) < 1e-9)
        #expect(abs((stats.generationDuration ?? 0) - 1.0) < 1e-9)
    }

    // OpenAI o-series style: 1000 reasoning tokens counted in usage but never streamed, then
    // 10 content chunks over 1 s. The hidden tokens fall outside the measured span.
    @Test func unstreamedReasoningIsLeftOutOfTheRate() throws {
        var m = GenerationMeter(requestStartedAt: t(0))
        for i in 0..<10 { m.record(ChatDelta(content: "x"), now: t(20 + Double(i) / 9)) }
        m.record(ChatDelta(usage: TokenUsage(promptTokens: 5, completionTokens: 1010, reasoningTokens: 1000)), now: t(21))
        let stats = try #require(m.finalStats())
        #expect(abs((stats.tokensPerSecond ?? 0) - 9) < 1e-6)   // (10 - 1) / 1 s, not 1009
        #expect(stats.completionTokens == 1010)                 // the stored count stays the server's
        #expect(stats.isEstimated == false)

        // Streamed reasoning is inside the span: the full count applies.
        var streamed = GenerationMeter(requestStartedAt: t(0))
        streamed.record(ChatDelta(reasoning: "r"), now: t(1))
        streamed.record(ChatDelta(content: "x"), now: t(2))
        streamed.record(ChatDelta(usage: TokenUsage(completionTokens: 41, reasoningTokens: 30)), now: t(2))
        #expect(abs((streamed.tokensPerSecond ?? 0) - 40) < 1e-9)
    }

    @Test func llamaCppTimingsWin() throws {
        var m = GenerationMeter(requestStartedAt: t(0))
        m.record(ChatDelta(content: "a"), now: t(1))
        m.record(ChatDelta(content: "b"), now: t(2))
        m.record(ChatDelta(finishReason: "stop", timings: ServerTimings(predictedTokens: 64, predictedMilliseconds: 500, predictedPerSecond: 128)), now: t(2))
        let stats = try #require(m.finalStats())
        #expect(stats.tokensPerSecond == 128)
        #expect(stats.completionTokens == 64)
        #expect(stats.generationDuration == 0.5)
        #expect(stats.isEstimated == false)
    }

    @Test func nothingGeneratedHasNoStats() {
        var m = GenerationMeter(requestStartedAt: t(0))
        m.record(ChatDelta(content: ""), now: t(1))
        m.record(ChatDelta(finishReason: "stop"), now: t(1))
        #expect(m.finalStats() == nil)
    }

    @Test func chunkParserReadsTimingsAndReasoningTokens() throws {
        let last = #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"timings":{"cache_n":3,"prompt_n":10,"prompt_ms":12.5,"predicted_n":64,"predicted_ms":500.0,"predicted_per_second":128.0}}"#
        let d = try #require(try ChunkParser.parse(last))
        #expect(d.finishReason == "stop")
        #expect(d.timings == ServerTimings(promptTokens: 10, promptMilliseconds: 12.5, cachedTokens: 3,
                                           predictedTokens: 64, predictedMilliseconds: 500, predictedPerSecond: 128))
        // A timings-only chunk is not dropped.
        #expect(try ChunkParser.parse(#"{"choices":[],"timings":{"predicted_n":5}}"#)?.timings?.predictedTokens == 5)
        let usage = #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":70,"total_tokens":75,"completion_tokens_details":{"reasoning_tokens":50}}}"#
        #expect(try ChunkParser.parse(usage)?.usage == TokenUsage(promptTokens: 5, completionTokens: 70, totalTokens: 75, reasoningTokens: 50))
    }

    @Test func requestBodyAsksForUsage() {
        let messages = [Message(role: .user, content: "hi")]
        let plain = ChatClient.buildRequestBody(messages: messages, options: ChatRequestOptions(model: "m"))
        #expect(plain["stream_options"] == nil)
        let withUsage = ChatClient.buildRequestBody(messages: messages, options: ChatRequestOptions(model: "m"), includeUsage: true)
        #expect((withUsage["stream_options"] as? [String: Bool]) == ["include_usage": true])
        #expect(Set(withUsage.keys) == ["model", "stream", "messages", "stream_options"])
    }

    @Test func streamOptionsRejectionHeuristic() {
        #expect(StreamOptionsSupport.isRejection(status: 400, body: #"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#))
        #expect(StreamOptionsSupport.isRejection(status: 422, body: #"{"detail":[{"type":"extra_forbidden","loc":["body","stream_options"],"msg":"Extra inputs are not permitted"}]}"#))
        #expect(!StreamOptionsSupport.isRejection(status: 400, body: #"{"error":{"message":"context length exceeded"}}"#))
        #expect(!StreamOptionsSupport.isRejection(status: 500, body: "stream_options"))
    }
}

// MARK: - Backward compatibility

@Suite struct GenerationStatsCompatibilityTests {
    /// A file exactly as the previous version wrote it: no `stats`, no `reasoningTokens`.
    private let oldConversationJSON = #"""
    {"createdAt":"2026-10-01T10:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","messages":[
      {"attachments":[],"content":"Hello","createdAt":"2026-10-01T10:00:00Z","id":"0E984725-C51C-4BF4-9960-E1C80E27ABA0","isComplete":true,"role":"user"},
      {"attachments":[],"content":"Hi!","createdAt":"2026-10-01T10:00:05Z","id":"1E984725-C51C-4BF4-9960-E1C80E27ABA0","isComplete":true,
       "model":"qwen3-14b","reasoning":"greet","reasoningDuration":0.5,"role":"assistant",
       "usage":{"completionTokens":3,"promptTokens":12,"totalTokens":15}}
    ],"settings":{"model":"qwen3-14b","systemPrompt":""},"title":"Old chat","updatedAt":"2026-10-01T10:00:05Z"}
    """#

    private func checkOld(_ c: Conversation) {
        #expect(c.title == "Old chat")
        #expect(c.messages.count == 2)
        #expect(c.messages[1].usage == TokenUsage(promptTokens: 12, completionTokens: 3, totalTokens: 15))
        #expect(c.messages[1].stats == nil)
        #expect(c.messages[1].usage?.reasoningTokens == nil)
    }

    @Test func oldPlainFileDecodes() throws {
        let file = #"{"conversation":"# + oldConversationJSON + #","encrypted":false,"format":"parley.conversation","version":1}"#
        checkOld(try ConversationFile.decodePlain(Data(file.utf8)))
    }

    @Test func oldEncryptedFileDecodes() throws {
        // Seal the old plaintext the way the previous version did.
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let key = try ConversationCrypto.newKey(password: "pw", iterations: 1000)
        let aad = ConversationCrypto.aad(id: id, iterations: key.iterations, salt: key.salt)
        let payload = try ConversationCrypto.seal(Data(oldConversationJSON.utf8), key: key.key, aad: aad)
        let envelope: [String: Any] = [
            "format": "parley.conversation", "version": 1, "encrypted": true, "id": id.uuidString.uppercased(),
            "kdf": ["name": ConversationCrypto.kdfName, "iterations": key.iterations, "salt": key.salt.base64EncodedString()],
            "cipher": ConversationCrypto.cipherName, "payload": payload.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        checkOld(try ConversationFile.decodeEncrypted(data, key: key))
        checkOld(try ConversationFile.decodeEncrypted(data, password: "pw").0)
    }

    @Test func newFieldsRoundTrip() throws {
        let stats = GenerationStats(tokensPerSecond: 42.5, completionTokens: 236, timeToFirstToken: 0.25, generationDuration: 5.5, isEstimated: true)
        let message = Message(role: .assistant, content: "x", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              usage: TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, reasoningTokens: 1), stats: stats)
        let conversation = Conversation(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), messages: [message])
        let plain = try ConversationFile.decodePlain(ConversationFile.encode(conversation, encryption: nil))
        #expect(plain.messages[0].stats == stats)
        #expect(plain.messages[0].usage?.reasoningTokens == 1)
        let key = try ConversationCrypto.newKey(password: "pw", iterations: 1000)
        let sealed = try ConversationFile.decodeEncrypted(ConversationFile.encode(conversation, encryption: key), key: key)
        #expect(sealed.messages[0].stats == stats)
        // A stats object with fields this version does not know (or lacks) still decodes.
        let partial = try JSONDecoder().decode(GenerationStats.self, from: Data(#"{"tokensPerSecond":3,"futureField":1}"#.utf8))
        #expect(partial == GenerationStats(tokensPerSecond: 3))
    }
}

// MARK: - Against the mock server

private let python3Path = "/usr/bin/python3"
private let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/mock_server.py")

private struct MockError: Error, CustomStringConvertible { let description: String }

private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
    }
    guard ok else { throw POSIXError(.EADDRINUSE) }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Starts tools/mock_server.py with a flavor on a free 127.0.0.1 port.
private func withMock(_ flavor: String = "lmstudio", _ body: (String) async throws -> Void) async throws {
    let port = try freePort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python3Path)
    process.arguments = ["-I", "-u", mockServerScript.path, String(port), flavor]
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
    // A port can be handed out again in this process: what an earlier server on it refused is not this one's.
    StreamOptionsSupport.forget(baseURL: URL(string: base)!)
    let probe = try ChatClient(baseURL: base, apiKey: nil)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        guard process.isRunning else { throw MockError(description: "mock server exited") }
        if (try? await probe.listModels()) != nil { return try await body(base) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw MockError(description: "mock server did not start")
}

private func counters(_ base: String) async throws -> [String: Int] {
    let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/mock/requests")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Int] ?? [:]
}

private func stream(_ base: String, model: String) async throws -> (StreamAccumulator, GenerationMeter) {
    let client = try ChatClient(baseURL: base, apiKey: "test-key-not-secret")
    var acc = StreamAccumulator()
    var meter = GenerationMeter(requestStartedAt: Date())
    for try await delta in client.streamChat(messages: [Message(role: .user, content: "hello")], options: ChatRequestOptions(model: model)) {
        acc.apply(delta)
        meter.record(delta)
    }
    acc.finish()
    return (acc, meter)
}

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
struct ContextIntegrationTests {
    @Test func lmStudioProbe() async throws {
        try await withMock { base in
            let client = try ChatClient(baseURL: base, apiKey: "test-key-not-secret")
            let info = await client.fetchModelInfo(model: "mock-plain")
            #expect(info.serverKind == .lmStudio)
            #expect(info.loadedContextLength == 8192)
            #expect(info.maxContextLength == 32768)
            #expect(info.canSetContextLength)
            #expect(info.instanceIDs == ["mock-plain"])
            let idle = await client.fetchModelInfo(model: "mock-notloaded")
            #expect(idle.isLoaded == false && idle.loadedContextLength == nil && idle.maxContextLength == 131072)
        }
    }

    @Test func otherServerFlavors() async throws {
        try await withMock("lmstudio-v0") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info.serverKind == .lmStudio && info.loadedContextLength == 8192 && !info.canSetContextLength)
        }
        try await withMock("llamacpp") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info.serverKind == .llamaCpp && info.loadedContextLength == 16384 && info.maxContextLength == 131072)
        }
        try await withMock("vllm") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info.serverKind == .vLLM && info.loadedContextLength == 32768)
        }
        try await withMock("ollama") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info.serverKind == .ollama && info.loadedContextLength == 4096)
        }
        try await withMock("plain") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info == ModelContextInfo(model: "mock-plain"))
        }
    }

    @Test func probeOfPathlessURLStaysQuiet() async throws {
        try await withMock { base in
            // No /v1: the list answers with LM Studio's 200 error body and there is no native root.
            let info = await (try ChatClient(baseURL: base.replacingOccurrences(of: "/v1", with: ""), apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info == ModelContextInfo(model: "mock-plain"))
        }
    }

    @Test func probeTimesOutQuickly() async throws {
        // A listener that accepts connections but never answers.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        try #require(ok && listen(fd, 16) == 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let client = try ChatClient(baseURL: "http://127.0.0.1:\(port)/v1", apiKey: nil)
        let start = Date()
        let answer = await client.probeJSON(URL(string: "http://127.0.0.1:\(port)/api/v1/models")!)
        #expect(answer == nil)
        #expect(Date().timeIntervalSince(start) < ChatClient.probeTimeout + 2)
    }

    @Test func reloadUnloadsThenLoads() async throws {
        try await withMock { base in
            let client = try ChatClient(baseURL: base, apiKey: "test-key-not-secret")
            let after = try await client.reloadModel("mock-plain", contextLength: 16384)
            #expect(after.loadedContextLength == 16384)
            // Exactly one instance: the old one was unloaded before loading (a plain load would add "mock-plain:2").
            #expect(after.instanceIDs == ["mock-plain"])
            let c = try await counters(base)
            #expect(c["unload"] == 1 && c["load"] == 1)

            // A model that was not loaded is just loaded.
            let idle = try await client.reloadModel("mock-notloaded", contextLength: 65536)
            #expect(idle.loadedContextLength == 65536 && idle.isLoaded == true)
            #expect(try await counters(base)["unload"] == 1)

            // Over the maximum: refused before anything is unloaded.
            await #expect(throws: ParleyError.self) { _ = try await client.reloadModel("mock-plain", contextLength: 1_000_000) }
            #expect(try await counters(base)["unload"] == 1)
            await #expect(throws: ParleyError.self) { _ = try await client.reloadModel("no-such-model", contextLength: 1000) }
        }
        // Servers without the LM Studio load API refuse cleanly.
        try await withMock("lmstudio-v0") { base in
            await #expect(throws: ParleyError.self) {
                _ = try await (try ChatClient(baseURL: base, apiKey: nil)).reloadModel("mock-plain", contextLength: 4096)
            }
        }
    }

    // Chatting with an instance id ("key:2"): every instance is unloaded and the key is loaded
    // again, so the result names the id that exists now.
    @Test func reloadOfAnInstanceIDReturnsTheNewID() async throws {
        try await withMock { base in
            var load = URLRequest(url: URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/api/v1/models/load")!)
            load.httpMethod = "POST"
            load.setValue("application/json", forHTTPHeaderField: "Content-Type")
            load.httpBody = Data(#"{"model":"mock-plain","context_length":4096}"#.utf8)
            _ = try await URLSession(configuration: .ephemeral).data(for: load)
            let client = try ChatClient(baseURL: base, apiKey: nil)
            #expect(await client.fetchModelInfo(model: "mock-plain:2").instanceIDs == ["mock-plain", "mock-plain:2"])

            let after = try await client.reloadModel("mock-plain:2", contextLength: 12000)
            #expect(after.model == "mock-plain")
            #expect(after.loadedContextLength == 12000)
            #expect(after.instanceIDs == ["mock-plain"])
        }
    }

    @Test func usageOnlyWhenAskedAndTimings() async throws {
        try await withMock { base in
            let (plain, meter) = try await stream(base, model: "mock-plain")
            #expect(plain.usage?.promptTokens == 10)          // stream_options was sent
            #expect(!meter.isEstimated)
            #expect(meter.generatedTokens == plain.usage?.completionTokens)
            let (_, timed) = try await stream(base, model: "mock-timings")
            #expect(timed.finalStats()?.tokensPerSecond == 123.4)
        }
    }

    @Test func streamOptionsFallback() async throws {
        try await withMock { base in
            let (first, meter) = try await stream(base, model: "mock-no-stream-options")
            #expect(first.content == #"You said: "hello" (0 images received)"#)
            #expect(first.usage == nil)
            #expect(meter.isEstimated)                         // counted from chunks
            var c = try await counters(base)
            #expect(c["stream_options_rejected"] == 1 && c["chat"] == 2)

            // A new client for the same base URL no longer sends stream_options.
            let (second, _) = try await stream(base, model: "mock-no-stream-options")
            #expect(second.content == first.content)
            c = try await counters(base)
            #expect(c["stream_options_rejected"] == 1 && c["chat"] == 3)

            // Ordinary 400s are not retried.
            await #expect(throws: ParleyError.self) { _ = try await stream(base, model: "mock-error") }
            #expect(try await counters(base)["chat"] == 4)
        }
    }
}
