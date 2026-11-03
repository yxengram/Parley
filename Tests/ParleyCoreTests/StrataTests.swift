import Foundation
import Testing
@testable import ParleyCore

// Strata (github.com/Niko1221/Strata): recognizing its shared port and its engine server from
// the shapes they really send, its overflow errors, prompt progress and timings, the fields only
// Strata gets, and the request-size cap. Network tests only ever talk to tools/mock_server.py on
// 127.0.0.1 (flavors strata-share and strata-engine).

private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

// MARK: - Recognition

@Suite struct StrataParserTests {
    // apps/host/server/index.mjs, native mode: no context field (Strata issue #3931).
    private let shareNative = #"""
    {"object":"list","data":[{"id":"qwen3.8-flash-next","object":"model","owned_by":"strata",
      "meta":{"instanceId":"a1b2","gpus":[0],"label":"Qwen3.8 Flash Next","aliases":["qwen"]}}]}
    """#
    // Runtime mode: meta.context in tokens.
    private let shareRuntime = #"""
    {"object":"list","data":[{"id":"qwen3.8-flash-next","object":"model","created":1793700000,"owned_by":"strata",
      "meta":{"label":"qwen3.8","context":131072,"instanceId":"r1","gpuIds":["0"],"mode":"single"}}]}
    """#
    // serve/server.py GET /v1/models: no owned_by, status, meta.n_ctx, architecture.
    private let engine = #"""
    {"object":"list","data":[
      {"id":"qwen3.8-flash-next","object":"model","status":{"value":"loaded"},"meta":{"n_ctx":65536},
       "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"aliases":["qwen"]},
      {"id":"deepseek-v4.1","object":"model","status":{"value":"unloaded"},"meta":{"n_ctx":32768},
       "architecture":{"input_modalities":["text"],"output_modalities":["text"]}}]}
    """#

    @Test func sharedPortIsStrataWithItsBodyLimit() throws {
        let info = try #require(ChatClient.parseModelList(try json(shareNative), model: "qwen3.8-flash-next"))
        #expect(info.serverKind == .strata)
        #expect(info.loadedContextLength == nil)          // native mode reports none
        #expect(info.maxRequestBytes == 12 * 1024 * 1024)
        #expect(!info.canSetContextLength)
        // A model the list does not have still tells the kind.
        #expect(ChatClient.parseModelList(try json(shareNative), model: "other")?.serverKind == .strata)

        let runtime = try #require(ChatClient.parseModelList(try json(shareRuntime), model: "qwen3.8-flash-next"))
        #expect(runtime.serverKind == .strata && runtime.loadedContextLength == 131072)
        #expect(runtime.maxRequestBytes == 4 * 1024 * 1024)
        #expect(InferenceServerKind.strata.displayName == "Strata")
    }

    @Test func engineListShape() throws {
        let list = try json(engine)
        #expect(ChatClient.looksLikeStrataEngine(list))
        let qwen = try #require(ChatClient.parseModelList(list, model: "qwen3.8-flash-next"))
        #expect(qwen.loadedContextLength == 65536 && qwen.isLoaded == true && qwen.acceptsImages == true)
        let ds = try #require(ChatClient.parseModelList(list, model: "deepseek-v4.1"))
        #expect(ds.loadedContextLength == 32768 && ds.isLoaded == false && ds.acceptsImages == false)

        // llama.cpp's router list has a status too, but names itself; OpenRouter has no meta.n_ctx.
        #expect(!ChatClient.looksLikeStrataEngine(try json(#"{"data":[{"id":"m","owned_by":"llamacpp","status":{"value":"loaded"},"meta":{"n_ctx":4096}}]}"#)))
        #expect(!ChatClient.looksLikeStrataEngine(try json(#"{"data":[{"id":"m","context_length":8192,"architecture":{"input_modalities":["text"]}}]}"#)))
        #expect(!ChatClient.looksLikeStrataEngine(try json(shareNative)))
    }

    @Test func engineHealth() throws {
        let health = try json(#"{"status":"ok","max_context":65536,"model":"qwen3.8-flash-next","images":false,"api_key":true,"image_generation":false,"loaded":true,"service":"strata"}"#)
        let info = try #require(ChatClient.parseStrataHealth(health, model: "qwen3.8-flash-next"))
        #expect(info == ModelContextInfo(model: "qwen3.8-flash-next", serverKind: .strata, loadedContextLength: 65536,
                                         isLoaded: true, acceptsImages: false))
        // Another model (PolyStrata serves several): only the kind applies.
        #expect(ChatClient.parseStrataHealth(health, model: "deepseek-v4.1") == ModelContextInfo(model: "deepseek-v4.1", serverKind: .strata))
        // While the engine starts, max_context is 0: unknown, not zero.
        let starting = try json(#"{"status":"ok","max_context":0,"model":"m","loaded":false,"service":"strata"}"#)
        #expect(ChatClient.parseStrataHealth(starting, model: "m")?.loadedContextLength == nil)
        // Anything else answering /health.
        #expect(ChatClient.parseStrataHealth(try json(#"{"status":"ok"}"#), model: "m") == nil)
        #expect(ChatClient.parseStrataHealth(try json(#"{"error":"Unexpected endpoint or method. (GET /health)"}"#), model: "m") == nil)
    }
}

// MARK: - Overflow, budget, reasoning

@Suite struct StrataBudgetTests {
    // serve/server.py Service.prepare, verbatim.
    static let promptTooLong = #"HTTP 400: {"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (40123 tokens) leaves no room to answer in the context (32768); requests are never truncated"}}"#
    static let maxTokensTooLarge = #"HTTP 400: {"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (30000 tokens) + max tokens (8192) exceeds the context (32768); requests are never truncated. Send a smaller max_tokens (at most 2760 here), or add \"fit_max_tokens\": true to the model's strata-<model>.json to shorten it to the room left (#545)"}}"#

    @Test func overflowErrorsNameTheContext() {
        #expect(ContextBudget.contextLength(fromError: Self.promptTooLong) == 32768)
        #expect(ContextBudget.contextLength(fromError: Self.maxTokensTooLarge) == 32768)
        #expect(ContextBudget.strataOverflow(fromError: Self.promptTooLong)
                == ContextBudget.Overflow(promptTokens: 40123, contextLength: 32768, maxTokens: nil, room: nil))
        #expect(ContextBudget.strataOverflow(fromError: Self.maxTokensTooLarge)
                == ContextBudget.Overflow(promptTokens: 30000, contextLength: 32768, maxTokens: 8192, room: 2760))
        // "at most 0 here" is a real answer.
        #expect(ContextBudget.strataOverflow(fromError: "request exceeds the context window: prompt (10 tokens) + max tokens (9) exceeds the context (16); … (at most 0 here)")?.room == 0)
        #expect(ContextBudget.strataOverflow(fromError: "HTTP 503: the engine is starting") == nil)
        // The older patterns still win where they match.
        #expect(ContextBudget.contextLength(fromError: "exceeds the available context size (8192 tokens)") == 8192)
    }

    // Strata, llama.cpp and LM Studio report no reasoning_tokens, and Parley never sends thinking
    // back: the next prompt is smaller than prompt + completion by the thinking.
    @Test func unreportedReasoningIsEstimatedOut() {
        let thinking = String(repeating: "abcd", count: 500)        // ≈ 500 tokens
        let reply = Message(role: .assistant, content: "ok", reasoning: thinking,
                            usage: TokenUsage(promptTokens: 1000, completionTokens: 520, totalTokens: 1520))
        #expect(ContextBudget.usage(messages: [reply], systemPrompt: "").tokens == 1020)
        // Never more than the completion.
        let short = Message(role: .assistant, content: "ok", reasoning: thinking,
                            usage: TokenUsage(promptTokens: 1000, completionTokens: 100))
        #expect(ContextBudget.usage(messages: [short], systemPrompt: "").tokens == 1000)
        // A reported count wins over the estimate.
        var reported = reply
        reported.usage?.reasoningTokens = 300
        #expect(ContextBudget.usage(messages: [reported], systemPrompt: "").tokens == 1220)
        // No reasoning text, nothing subtracted.
        let plain = Message(role: .assistant, content: "ok", usage: TokenUsage(promptTokens: 1000, completionTokens: 520))
        #expect(ContextBudget.usage(messages: [plain], systemPrompt: "").tokens == 1520)
    }
}

// MARK: - Stream chunks and speed

@Suite struct StrataStreamTests {
    @Test func promptProgressChunk() throws {
        // serve/server.py openai_chunks: an empty delta plus llama.cpp's prompt_progress.
        let payload = #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":null}],"prompt_progress":{"total":40960,"cache":30000,"processed":35480,"time_ms":5200}}"#
        let delta = try #require(try ChunkParser.parse(payload))
        let progress = try #require(delta.promptProgress)
        #expect(progress == PromptProgress(total: 40960, cached: 30000, processed: 35480, milliseconds: 5200))
        #expect(abs(progress.fraction - 0.5) < 1e-9)                 // (35480 - 30000) / (40960 - 30000)
        #expect(PromptProgress(total: 100, cached: 100, processed: 100).fraction == 1)
        #expect(delta.content == nil && delta.reasoning == nil)
    }

    @Test func lastChunkUsageAndTimings() throws {
        let last = #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":40960,"completion_tokens":512,"total_tokens":41472,"prompt_tokens_details":{"cached_tokens":30000}},"timings":{"cache_n":30000,"prompt_n":10960,"prompt_ms":12895.3,"prompt_per_token_ms":1.18,"prompt_per_second":849.9,"predicted_n":512,"predicted_ms":8323.6,"predicted_per_token_ms":16.26,"predicted_per_second":61.5}}"#
        let delta = try #require(try ChunkParser.parse(last))
        #expect(delta.usage?.cachedPromptTokens == 30000)
        #expect(delta.timings?.promptPerSecond == 849.9)

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var meter = GenerationMeter(requestStartedAt: start)
        meter.record(ChatDelta(content: ""), now: start)
        meter.record(ChatDelta(promptProgress: PromptProgress(total: 40960, cached: 30000, processed: 35000)), now: start.addingTimeInterval(5))
        #expect(meter.promptProgress?.processed == 35000)
        meter.record(ChatDelta(reasoning: "Hmm"), now: start.addingTimeInterval(13))
        #expect(meter.promptProgress == nil)                         // reading is over at the first token
        meter.record(ChatDelta(content: "x"), now: start.addingTimeInterval(14))
        meter.record(delta, now: start.addingTimeInterval(21))
        let stats = try #require(meter.finalStats())
        #expect(stats.tokensPerSecond == 61.5)                       // the server's own decode rate
        #expect(stats.completionTokens == 512 && stats.isEstimated == false)
        #expect(stats.finishReason == "length")
        #expect(stats.promptTokensRead == 10960 && stats.cachedPromptTokens == 30000)
        #expect(stats.promptTokensPerSecond == 849.9)
        #expect(abs((stats.timeToFirstToken ?? 0) - 13) < 1e-9)       // measured here: includes queueing and network
    }

    @Test func promptRateFromCountAndTime() {
        #expect(ServerTimings(promptTokens: 1000, promptMilliseconds: 500).promptRate == 2000)
        #expect(ServerTimings(promptTokens: 1000).promptRate == nil)
    }
}

// MARK: - Request body

@Suite struct StrataRequestTests {
    private let messages = [Message(role: .user, content: "hi")]

    private func options(_ kind: InferenceServerKind?, off: Bool = false, budget: Int? = nil, effort: ReasoningEffort? = nil) -> ChatRequestOptions {
        var o = ChatRequestOptions(model: "m", reasoningEffort: effort)
        o.serverKind = kind
        o.disablesThinking = off
        o.reasoningBudgetTokens = budget
        return o
    }

    @Test func strataFieldsOnlyForStrata() {
        let strata = ChatClient.buildRequestBody(messages: messages, options: options(.strata, budget: 2048, effort: .low))
        #expect(strata["return_progress"] as? Bool == true)
        #expect(strata["reasoning_effort"] as? String == "low")
        #expect(strata["reasoning_budget_tokens"] as? Int == 2048)

        let off = ChatClient.buildRequestBody(messages: messages, options: options(.strata, off: true, budget: 2048))
        #expect(off["reasoning_effort"] as? String == "none")
        #expect(off["reasoning_budget_tokens"] == nil)              // no thinking, no budget

        let kinds: [InferenceServerKind?] = [nil, .lmStudio, .llamaCpp, .vLLM, .ollama, .hosted]
        for kind in kinds {
            let body = ChatClient.buildRequestBody(messages: messages, options: options(kind, off: true, budget: 2048), includeUsage: true)
            #expect(Set(body.keys) == ["model", "stream", "messages", "stream_options"], "\(String(describing: kind))")
            let withEffort = ChatClient.buildRequestBody(messages: messages, options: options(kind, effort: .high))
            #expect(withEffort["reasoning_effort"] as? String == "high")
            #expect(withEffort["return_progress"] == nil)
        }
    }

    @Test func settingsCarryThinkingOffAndBudget() {
        var settings = ConversationSettings(model: "m", reasoningEffort: nil)
        settings.disablesThinking = true
        settings.reasoningBudgetTokens = 1024
        let o = ChatRequestOptions(settings: settings)
        #expect(o.disablesThinking && o.reasoningBudgetTokens == 1024 && o.serverKind == nil)
    }

    // The new settings fields are optional: an old file decodes, a new one keeps them, and the
    // keys an older version does not know are ignored by it (synthesized Decodable).
    @Test func settingsFieldsAreBackwardCompatible() throws {
        let old = try JSONDecoder().decode(ConversationSettings.self, from: Data(#"{"model":"m","systemPrompt":"","reasoningEffort":"high"}"#.utf8))
        #expect(old.disablesThinking == nil && old.reasoningBudgetTokens == nil && old.reasoningEffort == .high)
        var settings = ConversationSettings(model: "m")
        settings.disablesThinking = true
        settings.reasoningBudgetTokens = 512
        let conversation = Conversation(settings: settings, messages: [
            Message(role: .assistant, content: "x", usage: TokenUsage(promptTokens: 5),
                    stats: GenerationStats(tokensPerSecond: 3, finishReason: "length", promptTokensRead: 4,
                                           promptTokensPerSecond: 800, cachedPromptTokens: 1)),
        ])
        let data = try ConversationFile.encode(conversation, encryption: nil)
        let back = try ConversationFile.decodePlain(data)
        #expect(back.settings == settings)
        #expect(back.messages[0].stats?.finishReason == "length" && back.messages[0].stats?.cachedPromptTokens == 1)
        let key = try ConversationCrypto.newKey(password: "pw", iterations: 1000)
        let sealed = try ConversationFile.decodeEncrypted(ConversationFile.encode(conversation, encryption: key), key: key)
        #expect(sealed.settings == settings && sealed.messages[0].stats == conversation.messages[0].stats)
        // Old stats objects (no new keys) still decode.
        let oldStats = try JSONDecoder().decode(GenerationStats.self, from: Data(#"{"tokensPerSecond":3,"isEstimated":false}"#.utf8))
        #expect(oldStats.finishReason == nil && oldStats.cachedPromptTokens == nil)
    }

    // Strata's shared port answers a body over 12 MiB with a bare 500 (or a reset connection);
    // it is refused here before anything is sent (port 1: nothing listens).
    @Test func oversizedRequestIsRefusedBeforeSending() async throws {
        let client = try ChatClient(baseURL: "http://127.0.0.1:1/v1", apiKey: nil)
        var o = ChatRequestOptions(model: "m")
        o.maxRequestBytes = 1000
        let big = [Message(role: .user, content: String(repeating: "x", count: 2000))]
        do {
            for try await _ in client.streamChat(messages: big, options: o) {}
            Issue.record("expected an error")
        } catch let error as ParleyError {
            guard case .api(let message) = error else { Issue.record("\(error)"); return }
            #expect(message.contains("the server accepts"))
            #expect(message.contains("fork from a message before the first image"))
        }
    }
}

// MARK: - Against the mock server

private let python3Path = "/usr/bin/python3"
private let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/mock_server.py")
private let testKey = "test-key-not-secret"

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

/// Starts tools/mock_server.py with a Strata flavor that wants `testKey`.
private func withStrata(_ flavor: String, _ body: (String) async throws -> Void) async throws {
    let port = try freePort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python3Path)
    process.arguments = ["-I", "-u", mockServerScript.path, String(port), flavor, testKey]
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
    let probe = try ChatClient(baseURL: base, apiKey: testKey)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        guard process.isRunning else { throw MockError(description: "mock server exited") }
        if (try? await probe.listModels()) != nil { return try await body(base) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw MockError(description: "mock server did not start")
}

private func mockJSON(_ base: String, _ path: String) async throws -> [String: Any] {
    let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + path)!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private func strataOptions(_ model: String, kind: InferenceServerKind? = .strata) -> ChatRequestOptions {
    var o = ChatRequestOptions(model: model)
    o.serverKind = kind
    return o
}

private func stream(_ base: String, _ options: ChatRequestOptions,
                    messages: [Message] = [Message(role: .user, content: "hello")]) async throws -> (StreamAccumulator, GenerationMeter, [ChatDelta]) {
    let client = try ChatClient(baseURL: base, apiKey: testKey)
    var acc = StreamAccumulator()
    var meter = GenerationMeter(requestStartedAt: Date())
    var deltas: [ChatDelta] = []
    for try await delta in client.streamChat(messages: messages, options: options) {
        deltas.append(delta)
        acc.apply(delta)
        meter.record(delta)
    }
    acc.finish()
    return (acc, meter, deltas)
}

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
struct StrataIntegrationTests {
    @Test func sharedPortProbeAsksNothingElse() async throws {
        try await withStrata("strata-share") { base in
            let info = await (try ChatClient(baseURL: base, apiKey: testKey)).fetchModelInfo(model: "strata-qwen")
            #expect(info.serverKind == .strata)
            #expect(info.loadedContextLength == nil && info.maxRequestBytes == strataShareBodyLimit)
            // Only /v1/models was asked: no /props, /api/*, /health 404s (127.0.0.1 counts as local).
            #expect(try await mockJSON(base, "/mock/requests")["get_other"] as? Int == 0)
            // Without the key: 401 {"error":"Invalid API key"}, nothing learned.
            let anonymous = await (try ChatClient(baseURL: base, apiKey: nil)).fetchModelInfo(model: "strata-qwen")
            #expect(anonymous.serverKind == nil)
            await #expect(throws: ParleyError.self) { _ = try await ChatClient(baseURL: base, apiKey: nil).listModels() }
        }
    }

    // The shared port lists ready models only: one still loading is missing from the list, which
    // still names the server.
    @Test func sharedPortLeavesLoadingModelsOut() async throws {
        try await withStrata("strata-share") { base in
            let client = try ChatClient(baseURL: base, apiKey: testKey)
            let ids = try await client.listModels()
            #expect(ids.contains("strata-qwen") && !ids.contains("strata-loading"))
            let info = await client.fetchModelInfo(model: "strata-loading")
            #expect(info.serverKind == .strata && info.loadedContextLength == nil)
        }
    }

    // Strata checks the path, then the key, then the body size (local-share.mjs, index.mjs).
    @Test func sharedPortChecksTheKeyBeforeTheBodySize() async throws {
        try await withStrata("strata-share") { base in
            let session = URLSession(configuration: .ephemeral)
            func post(key: String?) async throws -> (Int, String) {
                var request = URLRequest(url: URL(string: base + "/chat/completions")!)
                request.httpMethod = "POST"
                if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
                request.httpBody = Data(count: strataShareBodyLimit + 1)
                let (data, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
            }
            let anonymous = try await post(key: nil)
            #expect(anonymous.0 == 401 && anonymous.1.contains("Invalid API key"))
            let keyed = try await post(key: testKey)
            #expect(keyed.0 == 500 && keyed.1 == "Request failed")
        }
    }

    @Test func engineProbeReadsHealth() async throws {
        try await withStrata("strata-engine") { base in
            let client = try ChatClient(baseURL: base, apiKey: testKey)
            let info = await client.fetchModelInfo(model: "strata-qwen")
            #expect(info.serverKind == .strata)
            #expect(info.loadedContextLength == 8192 && info.isLoaded == true && info.acceptsImages == false)
            #expect(info.maxRequestBytes == nil && !info.canSetContextLength)
            // Not the engine's current model: the list's own values.
            let other = await client.fetchModelInfo(model: "strata-nofit")
            #expect(other.serverKind == .strata && other.loadedContextLength == 8192 && other.isLoaded == false)
            #expect(try await mockJSON(base, "/mock/requests")["get_other"] as? Int == 0)   // /health went first: no LM Studio probes
        }
    }

    @Test func streamsProgressReasoningAndTimings() async throws {
        // The engine sends prompt progress when asked for it.
        try await withStrata("strata-engine") { base in
            let (_, _, deltas) = try await stream(base, strataOptions("strata-qwen"))
            #expect(deltas.contains { $0.promptProgress != nil })
        }
        try await withStrata("strata-share") { base in
            let (acc, meter, deltas) = try await stream(base, strataOptions("strata-qwen"))
            // Live, the share port sends none although Parley asks (keep-alive comments only).
            #expect(!deltas.contains { $0.promptProgress != nil })
            #expect(acc.reasoning == "The user wants an echo.")
            #expect(acc.content == #"You said: "hello" (0 images received)"#)
            #expect(acc.usage?.cachedPromptTokens != nil)
            let stats = try #require(meter.finalStats())
            #expect(stats.tokensPerSecond == 61.5 && stats.finishReason == "stop" && stats.isEstimated == false)
            #expect(stats.promptTokensPerSecond != nil)
            let sent = try await mockJSON(base, "/mock/last-request")
            #expect(sent["return_progress"] as? Bool == true)

            // Not known to be Strata: a plain request (keep-alive comments, no progress chunks).
            let (plain, _, plainDeltas) = try await stream(base, strataOptions("strata-qwen", kind: nil))
            #expect(plain.content == acc.content && !plainDeltas.contains { $0.promptProgress != nil })
            #expect(try await mockJSON(base, "/mock/last-request")["return_progress"] == nil)
        }
    }

    @Test func thinkingOffAndBudget() async throws {
        try await withStrata("strata-share") { base in
            var o = strataOptions("strata-qwen")
            o.disablesThinking = true
            let (acc, _, _) = try await stream(base, o)
            #expect(acc.reasoning.isEmpty && !acc.content.isEmpty)
            #expect(try await mockJSON(base, "/mock/last-request")["reasoning_effort"] as? String == "none")
            o.disablesThinking = false
            o.reasoningBudgetTokens = 256
            o.reasoningEffort = .medium
            _ = try await stream(base, o)
            let sent = try await mockJSON(base, "/mock/last-request")
            #expect(sent["reasoning_budget_tokens"] as? Int == 256 && sent["reasoning_effort"] as? String == "medium")
        }
    }

    @Test func overflowErrorsAndTheMaxTokensRule() async throws {
        try await withStrata("strata-share") { base in
            // fit_max_tokens off: max_tokens over the room is a 400 with Strata's own text.
            var o = strataOptions("strata-nofit")
            o.maxTokens = 9000
            do {
                _ = try await stream(base, o)
                Issue.record("expected an overflow")
            } catch {
                let text = error.localizedDescription
                #expect(ContextBudget.contextLength(fromError: text) == 8192)
                #expect(ContextBudget.strataOverflow(fromError: text)?.room == 8192 - 8 - 5)   // "hello": 4 + 5 / 4 tokens
            }
            // fit_max_tokens on (Strata's default): the same cap is sent as is and shortened there.
            o.model = "strata-qwen"
            let (acc, meter, _) = try await stream(base, o)
            #expect(!acc.content.isEmpty && meter.finalStats()?.finishReason == "stop")
            #expect(try await mockJSON(base, "/mock/last-request")["max_tokens"] as? Int == 9000)

            // A prompt that alone does not fit is always refused.
            let long = [Message(role: .user, content: String(repeating: "word ", count: 8000))]
            do {
                _ = try await stream(base, strataOptions("strata-qwen"), messages: long)
                Issue.record("expected an overflow")
            } catch {
                let overflow = ContextBudget.strataOverflow(fromError: error.localizedDescription)
                #expect(overflow?.contextLength == 8192 && overflow?.maxTokens == nil && (overflow?.promptTokens ?? 0) > 8192)
            }
        }
    }

    @Test func thinkingCanUseUpMaxTokens() async throws {
        try await withStrata("strata-share") { base in
            let (acc, meter, _) = try await stream(base, strataOptions("strata-length"))
            #expect(acc.content.isEmpty && !acc.reasoning.isEmpty)
            #expect(meter.finalStats()?.finishReason == "length")
        }
    }

    @Test func refusalsArriveAsHTTPErrors() async throws {
        try await withStrata("strata-share") { base in
            let image = Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50]))
            let withImage = [Message(role: .user, content: "look", attachments: [image])]
            await #expect(throws: ParleyError.self) { _ = try await stream(base, strataOptions("strata-novision"), messages: withImage) }
            do {
                _ = try await stream(base, strataOptions("strata-loading"))
                Issue.record("expected a refusal")
            } catch {
                #expect(error.localizedDescription.contains("This model is not ready."))
            }
        }
        try await withStrata("strata-engine") { base in
            let image = Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50]))
            do {
                _ = try await stream(base, strataOptions("strata-qwen"), messages: [Message(role: .user, content: "look", attachments: [image])])
                Issue.record("expected a refusal")
            } catch {
                #expect(error.localizedDescription.contains("started without the vision encoder"))
            }
            do {
                _ = try await stream(base, strataOptions("strata-loading"))
                Issue.record("expected a refusal")
            } catch {
                #expect(error.localizedDescription.hasPrefix("HTTP 503:") && error.localizedDescription.contains("the engine is starting"))
            }
        }
    }
}
