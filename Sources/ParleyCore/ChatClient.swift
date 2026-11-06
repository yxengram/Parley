import Foundation

// HTTP client for OpenAI-compatible endpoints. It contacts only the configured base URL,
// uses an ephemeral session (no cache, no cookies, no credential storage) and never logs
// request or response content.

public struct ChatRequestOptions: Sendable {
    public var model: String
    public var systemPrompt: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    /// "None (no thinking)" (ConversationSettings.disablesThinking). Sent to every server, in the
    /// shape `thinkingOffFields(for: serverKind)` gives.
    public var disablesThinking = false
    /// Leave the "no thinking" fields out although `disablesThinking` is set: this server refused
    /// them (earlier this launch, or in this request's first attempt). Everything else, the
    /// Strata thinking budget rule included, still follows `disablesThinking`.
    public var omitsThinkingOff = false
    /// ConversationSettings.reasoningBudgetTokens. Sent only to Strata.
    public var reasoningBudgetTokens: Int?
    /// What the app knows about the server (ModelContextInfo.serverKind). Fields only one server
    /// understands are sent only when this names it: an unknown field can be refused elsewhere.
    public var serverKind: InferenceServerKind?
    /// ModelContextInfo.maxRequestBytes: a larger request is refused before it is sent.
    public var maxRequestBytes: Int?
    /// Offered to the model. Nil or empty sends no `tools` key, and the body is what it was before
    /// tools existed.
    public var tools: [ChatTool]? = nil
    /// Leave `tools` out, and flatten earlier tool rounds into text: the server refused them, or
    /// the round cap was reached.
    public var omitsTools = false

    public init(model: String, systemPrompt: String = "", temperature: Double? = nil, maxTokens: Int? = nil, reasoningEffort: ReasoningEffort? = nil) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
    }

    public init(settings: ConversationSettings) {
        self.init(
            model: settings.model,
            systemPrompt: settings.systemPrompt,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            reasoningEffort: settings.reasoningEffort
        )
        disablesThinking = settings.disablesThinking ?? false
        reasoningBudgetTokens = settings.reasoningBudgetTokens
    }
}

public final class ChatClient: @unchecked Sendable {
    public let baseURL: URL
    private let apiKey: String?
    /// Shared with ModelInfo.swift: every request this client makes goes through this session.
    let session: URLSession
    private let chatURL: URL
    let modelsURL: URL

    private static let maxErrorBodyChars = 2000
    /// How much of an error response is read (HTML error pages carry several KB of inline CSS).
    static let maxErrorBodyBytes = 64 * 1024

    /// Appended to endpoint errors when the base URL has no path (a common slip: LM Studio,
    /// Ollama, vLLM and OpenAI all serve the API under /v1).
    public static let missingVersionPathHint =
        "The base URL has no path; OpenAI-compatible servers usually expect one ending in /v1 (for example http://host:1234/v1)."

    /// True when the base URL is just scheme://host[:port], with no version path.
    public var baseURLHasNoPath: Bool {
        baseURL.path.isEmpty || baseURL.path == "/"
    }

    /// Validates scheme http/https + host; throws invalidBaseURL.
    public init(baseURL: String, apiKey: String?) throws {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              let chat = URL(string: normalized + "/chat/completions"),
              let models = URL(string: normalized + "/models") else {
            throw ParleyError.invalidBaseURL(baseURL)
        }

        self.baseURL = url
        self.chatURL = chat
        self.modelsURL = models
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (key?.isEmpty ?? true) ? nil : key
        // Redirects are refused: a 307/308 would replay the whole conversation to whatever host
        // the Location header names. A refused redirect surfaces as ParleyError.http(3xx, ...).
        self.session = URLSession(
            configuration: Self.makeConfiguration(),
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 600
        return config
    }

    // MARK: Models

    /// GET {base}/models → data[].id sorted
    public func listModels() async throws -> [String] {
        do {
            return try await fetchModels()
        } catch {
            throw withPathHint(error)
        }
    }

    private func fetchModels() async throws -> [String] {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ParleyError.http(status: status, body: ResponseText.errorBody(status: status, response: response as? HTTPURLResponse, data: data))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            // A 200 HTML page: a captive portal or a proxy's sign-in page, never a model list.
            let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if ResponseText.isHTML(text) {
                throw ParleyError.api("The server answered with a web page (\(ResponseText.htmlSummary(text))) instead of a model list.")
            }
            throw ParleyError.api("The server's model list is not valid JSON.")
        }
        var ids: [String] = []
        func collect(_ list: [Any]) {
            for item in list {
                if let dict = item as? [String: Any] {
                    if let id = dict["id"] as? String { ids.append(id) }
                    else if let name = dict["name"] as? String { ids.append(name) }
                } else if let s = item as? String {
                    ids.append(s)
                }
            }
        }
        if let root = object as? [String: Any] {
            // Some servers (LM Studio for an unknown endpoint) answer 200 with an error body.
            if let error = root["error"], !(error is NSNull) {
                throw ParleyError.api(ChunkParser.errorMessage(from: error))
            }
            if (root["object"] as? String) == "error" {
                throw ParleyError.api(ChunkParser.errorMessage(from: root))
            }
            if let list = root["data"] as? [Any] { collect(list) }
            else if let list = root["models"] as? [Any] { collect(list) }
            else { throw ParleyError.api("The server's model list has an unexpected format.") }
        } else if let list = object as? [Any] {
            collect(list)
        } else {
            throw ParleyError.api("The server's model list has an unexpected format.")
        }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Chat

    /// POST {base}/chat/completions with stream:true. Non-2xx → ParleyError.http(status, body ≤ 2000 chars).
    /// Cancelling the consuming Task cancels the request.
    ///
    /// Asks for `stream_options: {include_usage: true}` (a final usage chunk). A server that
    /// rejects that field with HTTP 400/422 gets the same request once more without it, and is
    /// remembered (per base URL, in memory) so later requests leave it out.
    ///
    /// Likewise, a request carrying the "no thinking" fields (`thinkingOffFields`) that the server
    /// answers with an HTTP 400/422 refusing them (ThinkingOffSupport.isRejection; never on Strata)
    /// is sent once more without them. Only when that second request is answered with a 2xx does
    /// the stream first yield a `ChatDelta` with only `thinkingOffRejected` set; the caller then
    /// remembers the refusal (per provider and model) and tells the user that this reply used the
    /// server's default thinking. When the second request fails too, the field was not the cause:
    /// the first answer's error is thrown and nothing is yielded.
    /// A request carrying `tools` that the server refuses (ToolsSupport.refusal) goes the same way:
    /// it is sent once more without them, and only a 2xx answer makes the stream first yield a
    /// `ChatDelta` with only `toolsRejected` set. Each retry happens at most once per call, in any order.
    public func streamChat(messages: [Message], options: ChatRequestOptions) -> AsyncThrowingStream<ChatDelta, Error> {
        let includeUsage = !StreamOptionsSupport.isRejected(by: baseURL)
        let request: URLRequest
        do {
            request = try makeChatRequest(messages: messages, options: options, includeUsage: includeUsage)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream<ChatDelta, Error> { continuation in
            // The task holds `self` (and so the session) until the stream ends, even if the
            // caller drops its reference to the client.
            let task = Task {
                do {
                    var request = request
                    var options = options
                    var includeUsage = includeUsage
                    // The first answer's error while the request is being retried without the
                    // "no thinking" fields: thrown if that retry is refused too.
                    var thinkingOffRefusal: ParleyError?
                    // Likewise for the retry without `tools`.
                    var toolsRefusal: (refusal: ToolsRefusal, error: ParleyError)?
                    while true {
                        let thinkingOff = Self.sentThinkingOffFields(options)
                        do {
                            try await self.runStream(request: request, rejectsStreamOptions: includeUsage,
                                                     thinkingOffFields: thinkingOff, serverKind: options.serverKind,
                                                     sentTools: Self.sendsTools(options),
                                                     announcesThinkingOffRefusal: thinkingOffRefusal != nil,
                                                     announcesToolsRefusal: toolsRefusal?.refusal,
                                                     continuation: continuation)
                            break
                        } catch is StreamOptionsRejected {
                            // Nothing was yielded yet (the server answered with an error status).
                            StreamOptionsSupport.markRejected(by: self.baseURL)
                            includeUsage = false
                        } catch let rejected as ToolsRejected {
                            options.omitsTools = true
                            toolsRefusal = (rejected.refusal, rejected.error)
                        } catch let rejected as ThinkingOffRejected {
                            options.omitsThinkingOff = true
                            thinkingOffRefusal = rejected.error
                        } catch let error as ParleyError {
                            // The retry without the field was refused as well: the field was not
                            // the cause, so the server's first answer is the one to show.
                            if case .http = error, let first = toolsRefusal?.error ?? thinkingOffRefusal { throw first }
                            throw error
                        }
                        // Each retry turns its own flag off, so neither can be thrown twice.
                        request = try self.makeChatRequest(messages: messages, options: options, includeUsage: includeUsage)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: self.withPathHint(error))
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// With `rejectsStreamOptions`, an HTTP 400/422 whose body blames `stream_options` throws
    /// StreamOptionsRejected instead of the HTTP error, so the caller can retry without it. With
    /// `thinkingOffFields` (the "no thinking" keys this request carries), one that refuses them
    /// throws ThinkingOffRejected. With `announcesThinkingOffRefusal` (this is that retry), a 2xx
    /// answer first yields the `thinkingOffRejected` delta. `sentTools` and `announcesToolsRefusal`
    /// do the same for `tools`.
    private func runStream(
        request: URLRequest,
        rejectsStreamOptions: Bool,
        thinkingOffFields: [String],
        serverKind: InferenceServerKind?,
        sentTools: Bool,
        announcesThinkingOffRefusal: Bool,
        announcesToolsRefusal: ToolsRefusal?,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            // Enough for an HTML error page, whose code can sit behind several KB of inline CSS.
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= Self.maxErrorBodyBytes { break }
            }
            let body = ResponseText.errorBody(status: status, response: http, data: collected)
            if rejectsStreamOptions, StreamOptionsSupport.isRejection(status: status, body: body) {
                throw StreamOptionsRejected()
            }
            if sentTools, let kind = ToolsSupport.refusal(status: status, body: body) {
                throw ToolsRejected(refusal: ToolsRefusal(kind: kind, message: ToolsSupport.message(body: body)),
                                    error: ParleyError.http(status: status, body: body))
            }
            if ThinkingOffSupport.isRejection(status: status, body: body, sentFields: thinkingOffFields, serverKind: serverKind) {
                throw ThinkingOffRejected(error: ParleyError.http(status: status, body: body))
            }
            throw ParleyError.http(status: status, body: body)
        }
        if announcesThinkingOffRefusal {
            // The request without the "no thinking" fields was accepted: they were the cause.
            continuation.yield(ChatDelta(thinkingOffRejected: true))
        }
        if let announcesToolsRefusal {
            continuation.yield(ChatDelta(toolsRejected: announcesToolsRefusal))
        }

        // From here on the server has answered: a transport error is a broken reply, not an
        // unreachable server, and is reported as such (the partial text stays in the message).
        let viaCloudflare = http.map(Self.cameThroughCloudflare) ?? false
        do {
            try await readStream(bytes: bytes, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                 viaCloudflare: viaCloudflare, continuation: continuation)
        } catch let error as URLError where error.code != .cancelled {
            throw ParleyError.api(StreamInterruption.message(underlying: error.localizedDescription, viaCloudflare: viaCloudflare))
        }
    }

    /// `server: cloudflare` or a `cf-ray` header: the response passed through Cloudflare.
    static func cameThroughCloudflare(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Server") ?? "").lowercased() == "cloudflare"
            || response.value(forHTTPHeaderField: "CF-RAY") != nil
    }

    private func readStream(
        bytes: URLSession.AsyncBytes,
        contentType: String?,
        viaCloudflare: Bool,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {

        // A server that ignores stream:true answers with one plain JSON completion.
        let contentType = (contentType ?? "").lowercased()
        var progress = StreamProgress()
        if contentType.contains("application/json") {
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            try Task.checkCancellation()
            let text = String(decoding: collected, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.contains(where: { $0.hasPrefix("data:") }) {
                // Actually SSE, just mislabeled.
                var decoder = SSEDecoder()
                for line in lines {
                    if try Self.emit(decoder.feed(line: line), to: continuation, progress: &progress) { return }
                }
                _ = try Self.emit(decoder.finish(), to: continuation, progress: &progress)
            } else if let delta = try ChunkParser.parse(text) {
                continuation.yield(delta)
            }
            return
        }

        var decoder = SSEDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if try Self.emit(decoder.feed(line: line), to: continuation, progress: &progress) { return }
        }
        try Task.checkCancellation()
        if try Self.emit(decoder.finish(), to: continuation, progress: &progress) { return }
        // The body ended cleanly but the reply did not: no finish_reason and no [DONE] after
        // something was sent (a proxy or tunnel that closed the response, a server that died
        // between chunks). Every OpenAI-compatible server ends a reply with one or the other.
        if progress.yieldedAny && !progress.sawFinishReason {
            throw ParleyError.api(StreamInterruption.message(underlying: nil, viaCloudflare: viaCloudflare))
        }
    }

    private struct StreamProgress {
        var yieldedAny = false
        var sawFinishReason = false
    }

    /// Parses and yields payloads. Returns true once "[DONE]" is seen.
    private static func emit(
        _ payloads: [String],
        to continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation,
        progress: inout StreamProgress
    ) throws -> Bool {
        for payload in payloads {
            if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return true }
            if let delta = try ChunkParser.parse(payload) {
                progress.yieldedAny = true
                if delta.finishReason != nil { progress.sawFinishReason = true }
                continuation.yield(delta)
            }
        }
        return false
    }

    private func makeChatRequest(messages: [Message], options: ChatRequestOptions, includeUsage: Bool) throws -> URLRequest {
        let body = Self.buildRequestBody(messages: messages, options: options, includeUsage: includeUsage)
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        let data = try Self.encodeBody(body, options: options)
        if let limit = options.maxRequestBytes, data.count > limit {
            let carriesToolData = Self.sendsTools(options) || messages.contains { !($0.toolRounds ?? []).isEmpty }
            throw ParleyError.api(Self.requestTooLargeMessage(bytes: data.count, limit: limit, carriesToolData: carriesToolData))
        }
        request.httpBody = data
        return request
    }

    /// The request's bytes. With tools the keys are sorted: dictionary order is not stable, and
    /// llama.cpp and Strata render tools at the start of the prompt, so an order flip would miss
    /// the prefix cache on every round. Without tools the options are the empty ones of old.
    static func encodeBody(_ body: [String: Any], options: ChatRequestOptions) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: sendsTools(options) ? [.sortedKeys] : [])
    }

    /// Whether this request carries `tools`. Decides the shape of the whole body: tool messages go
    /// out only with tools (see `buildRequestBody`).
    public static func sendsTools(_ options: ChatRequestOptions) -> Bool {
        !options.omitsTools && !(options.tools ?? []).isEmpty
    }

    /// Strata's shared port answers an oversized body with a bare HTTP 500 "Request failed" (or
    /// drops the connection), and every later turn would fail the same way: images are re-sent.
    static func requestTooLargeMessage(bytes: Int, limit: Int, carriesToolData: Bool = false) -> String {
        func mb(_ n: Int) -> String { String(format: "%.1f MB", Double(n) / 1_048_576) }
        let advice = carriesToolData
            ? "Images and tool results are sent again with every message: fork from an earlier message or roll back."
            : "Images are sent again with every message: remove some, or fork from a message before the first image."
        return "This request is \(mb(bytes)), more than the \(mb(limit)) the server accepts. " + advice
    }

    /// The two sizes ("14.2 MB", "12.0 MB") of a `requestTooLargeMessage`, also with text appended.
    public static func requestTooLarge(in message: String) -> (bytes: String, limit: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^This request is ([\d.]+ MB), more than the ([\d.]+ MB) the server accepts\."#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let bytes = Range(match.range(at: 1), in: message), let limit = Range(match.range(at: 2), in: message)
        else { return nil }
        return (String(message[bytes]), String(message[limit]))
    }

    /// Adds `missingVersionPathHint` to errors that suggest the wrong endpoint was hit, but only
    /// when the base URL has no path. Other errors pass through unchanged.
    func withPathHint(_ error: Error) -> Error {
        guard baseURLHasNoPath, let parley = error as? ParleyError else { return error }
        switch parley {
        case .api(let message) where StreamInterruption.parse(message) == nil:
            return ParleyError.api(message + " " + Self.missingVersionPathHint)
        case .http(let status, let body) where status == 404 || status == 405:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParleyError.api("Endpoint not found (HTTP \(status))" + (detail.isEmpty ? "." : ": \(detail)") + " " + Self.missingVersionPathHint)
        default:
            return error
        }
    }

    func applyAuthorization(to request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    static func truncatedBody(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.count > maxErrorBodyChars ? String(text.prefix(maxErrorBodyChars)) : text
    }

    // MARK: Request body

    /// Pure, for tests. Returns the JSON body dictionary. With `includeUsage`, adds
    /// `stream_options: {include_usage: true}` (what streamChat sends unless the server refused it).
    ///
    /// Earlier tool rounds go out as `tool_calls` and `role: tool` messages only when this request
    /// carries `tools`. Otherwise they are flattened into assistant text (Message.flattenedForRequest):
    /// a retry without tools could fail the same way on a tool-shaped history, and Strata's runtime
    /// path keeps only `{role, content}`. A reply that is still open then ends in a user turn asking
    /// for the answer. `tool_choice` is never sent: Ollama has none, the rest default to auto.
    public static func buildRequestBody(messages: [Message], options: ChatRequestOptions, includeUsage: Bool = false) -> [String: Any] {
        var apiMessages: [[String: Any]] = []

        if !options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(["role": "system", "content": options.systemPrompt])
        }

        for message in messages {
            switch message.role {
            case .system:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                apiMessages.append(["role": "system", "content": message.content])

            case .assistant:
                // Never send reasoning back. Skip empty (e.g. failed) replies; partial content is sent as is.
                let rounds = message.toolRounds ?? []
                if rounds.isEmpty {
                    guard !Message.isBlank(message.content) else { continue }
                    apiMessages.append(["role": "assistant", "content": message.content])
                } else if sendsTools(options) {
                    for round in rounds {
                        var replay: [String: Any] = ["role": "assistant", "tool_calls": round.calls.map { call -> [String: Any] in
                            ["id": call.id, "type": "function",
                             "function": ["name": call.name, "arguments": call.replayArguments]]
                        }]
                        // LM Studio's documented form leaves `content` out when there is none.
                        if !Message.isBlank(round.content) { replay["content"] = round.content }
                        apiMessages.append(replay)
                        for call in round.calls {
                            apiMessages.append(["role": "tool", "tool_call_id": call.id, "name": call.name,
                                                "content": call.replayResult])
                        }
                    }
                    if !Message.isBlank(message.content) {
                        apiMessages.append(["role": "assistant", "content": message.content])
                    }
                } else {
                    let text = message.flattenedForRequest
                    if !Message.isBlank(text) { apiMessages.append(["role": "assistant", "content": text]) }
                }

            case .user:
                var text = message.content
                for attachment in message.attachments where attachment.kind == .text {
                    guard let fileText = attachment.text else { continue }
                    let name = attachment.filename.replacingOccurrences(of: "\"", with: "&quot;")
                    text += "\n\n<file name=\"\(name)\">\n\(fileText)\n</file>"
                }
                let images = message.attachments.filter { $0.kind == .image && $0.data != nil }
                if images.isEmpty {
                    apiMessages.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty {
                        parts.append(["type": "text", "text": text])
                    }
                    for image in images {
                        guard let data = image.data else { continue }
                        let mime = image.mimeType.isEmpty ? "image/jpeg" : image.mimeType
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"],
                        ])
                    }
                    apiMessages.append(["role": "user", "content": parts])
                }
            }
        }

        // A reply still open, going out without `tools` (the round limit, or tools were refused).
        if !sendsTools(options), let last = messages.last, last.role == .assistant, !(last.toolRounds ?? []).isEmpty,
           Message.isBlank(last.content) {
            apiMessages.append(["role": "user", "content": ToolResultText.answerNow])
        }

        var body: [String: Any] = [
            "model": options.model,
            "stream": true,
            "messages": apiMessages,
        ]
        if let t = options.temperature { body["temperature"] = t }
        if let m = options.maxTokens { body["max_tokens"] = m }
        if let r = options.reasoningEffort { body["reasoning_effort"] = r.rawValue }
        if includeUsage { body["stream_options"] = ["include_usage": true] }
        if options.disablesThinking && !options.omitsThinkingOff {
            // "None" replaces an effort (the picker never sets both).
            body["reasoning_effort"] = nil
            for (key, value) in thinkingOffFields(for: options.serverKind) { body[key] = value }
        }
        if options.serverKind == .strata {
            // Prompt-reading progress before the first token (llama.cpp's flag; best effort).
            body["return_progress"] = true
            if let budget = options.reasoningBudgetTokens, budget > 0, !options.disablesThinking {
                body["reasoning_budget_tokens"] = budget
            }
        }
        if sendsTools(options), let tools = options.tools {
            body["tools"] = tools.map { tool -> [String: Any] in
                var function: [String: Any] = ["name": tool.name, "parameters": tool.parameters.any]
                if let description = tool.description { function["description"] = description }
                return ["type": "function", "function": function]
            }
        }
        return body
    }

    /// What turns thinking off ("None (no thinking)") on each kind of server, on
    /// POST /v1/chat/completions. Only shapes the servers' own code or docs confirm; where nothing
    /// is confirmed, the one field most servers accept, and the app shows a note on the reply when
    /// it was refused (streamChat retries without it) or ignored (thinking still came back).
    public static func thinkingOffFields(for kind: InferenceServerKind?) -> [String: Any] {
        let effortNone: [String: Any] = ["reasoning_effort": "none"]
        let templateOff: [String: Any] = ["chat_template_kwargs": ["enable_thinking": false]]
        switch kind {
        case .strata:
            // Verified live; serve/frontend.py maps none/off/minimal/disabled/false to
            // enable_thinking=False (an unknown effort is a 400).
            return effortNone
        case .llamaCpp:
            // tools/server/server-common.cpp (README "chat_template_kwargs"): per-request kwargs since
            // b5780. (reasoning_effort "none" only from b10121; before, the field was ignored.)
            return templateOff
        case .vLLM:
            // chat_completion/protocol.py: chat_template_kwargs.enable_thinking wins and is dropped for
            // templates without it. reasoning_effort "none" is a 400 up to v0.17.1 and on gpt-oss.
            return templateOff
        case .ollama:
            // openai/openai.go: reasoning_effort "none" becomes think=false (v0.12.4+);
            // chat_template_kwargs is not read at all.
            return effortNone
        case .lmStudio, .hosted, nil:
            // LM Studio: reasoning_effort on chat completions since 0.4.8; "none" is undocumented but
            // turned thinking off in a live check (Qwen 3.8 27B, 2026-11-04). chat_template_kwargs is
            // ignored (bug tracker #1990). Hosted, best effort: OpenAI (gpt-5.1+), OpenRouter and
            // Gemini 2.5 Flash document "none"; other models refuse it.
            return effortNone
        }
    }

    /// The "no thinking" keys this request carries (none when it was not asked for or omitted).
    public static func sentThinkingOffFields(_ options: ChatRequestOptions) -> [String] {
        guard options.disablesThinking && !options.omitsThinkingOff else { return [] }
        return Array(thinkingOffFields(for: options.serverKind).keys)
    }

    // MARK: Host classification

    /// True if the host is loopback, private RFC1918, link-local, *.local, or a CGNAT/Tailscale 100.64/10 address.
    public static func isLocalHost(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if let percent = h.firstIndex(of: "%") {
            h = String(h[..<percent])
        }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }

        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") {
            return true
        }

        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network byte order
            return isLocalIPv4(b)
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            guard b.count == 16 else { return false }
            // ::1
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            // fe80::/10 link-local
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }
            // fc00::/7 unique local
            if (b[0] & 0xFE) == 0xFC { return true }
            // ::ffff:a.b.c.d IPv4-mapped
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return isLocalIPv4(Array(b[12..<16]))
            }
            return false
        }
        return false
    }

    private static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (127, _): return true                              // 127.0.0.0/8
        case (10, _): return true                               // 10.0.0.0/8
        case (172, let x) where (x & 0xF0) == 16: return true   // 172.16.0.0/12
        case (192, 168): return true                            // 192.168.0.0/16
        case (169, 254): return true                            // 169.254.0.0/16
        case (100, let x) where (x & 0xC0) == 64: return true   // 100.64.0.0/10
        default: return false
        }
    }
}

/// Thrown inside runStream when the server refused `stream_options`; never escapes streamChat.
struct StreamOptionsRejected: Error {}

/// Base URLs whose server rejected `stream_options`. Process-wide and memory only: clients are
/// short-lived (one per request), so the knowledge cannot live on an instance.
enum StreamOptionsSupport {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejected: Set<String> = []

    static func isRejected(by baseURL: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected.contains(baseURL.absoluteString)
    }

    static func markRejected(by baseURL: URL) {
        lock.lock(); defer { lock.unlock() }
        rejected.insert(baseURL.absoluteString)
    }

    /// Forgets one base URL (tests: a new mock server on a port an earlier one used). Never
    /// clears the whole set, which tests running in parallel rely on.
    static func forget(baseURL: URL) {
        lock.lock(); defer { lock.unlock() }
        rejected.remove(baseURL.absoluteString)
    }

    /// HTTP 400/422 whose body names the field (OpenAI: "Unrecognized request argument supplied:
    /// stream_options"; pydantic servers: "Extra inputs are not permitted" with loc
    /// ["body","stream_options"]). Other 400s (context overflow, bad model) are not retried.
    static func isRejection(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        return lower.contains("stream_options") || lower.contains("include_usage")
    }
}

/// Thrown inside runStream when the server refused the "no thinking" field; never escapes streamChat.
struct ThinkingOffRejected: Error {
    /// The server's answer, shown if the retry without the field is refused as well.
    let error: ParleyError
}

/// Whether an error answer refuses the "no thinking" field. What is remembered about it lives in
/// the app (per provider and model, AppState), not here: no process-wide state.
enum ThinkingOffSupport {
    /// HTTP 400/422 that refuses a field that was sent: the body names it (OpenAI `{"error":{"param":
    /// "reasoning_effort","code":"unsupported_value"|"unknown_parameter",…}}`, `reasoning.effort` in
    /// the Responses API's spelling, pydantic errors that list it) or speaks of what it controls
    /// ("reasoning" for reasoning_effort: Ollama's `invalid reasoning value`, LM Studio-style
    /// "reasoning effort"; "thinking" for either: Gemini's "Thinking can't be disabled"). Being
    /// loose here is safe: streamChat counts it as a refusal only if the retry without the field
    /// is accepted. Never on Strata, where "none" is verified (its 400s are about something
    /// else), and never for a context overflow or any other 400.
    static func isRejection(status: Int, body: String, sentFields: [String], serverKind: InferenceServerKind? = nil) -> Bool {
        guard status == 400 || status == 422, !sentFields.isEmpty, serverKind != .strata else { return false }
        let lower = body.lowercased()
        if ContextBudget.contextLength(fromError: body) != nil
            || lower.contains("context length") || lower.contains("context window") {
            return false
        }
        var names = sentFields.map { $0.lowercased() }
        if names.contains("reasoning_effort") { names += ["reasoning", "thinking"] }
        if names.contains("chat_template_kwargs") { names += ["enable_thinking", "chat template kwargs", "thinking"] }
        return names.contains { lower.contains($0) }
    }
}

/// Thrown inside runStream when the server refused `tools`; never escapes streamChat.
struct ToolsRejected: Error {
    let refusal: ToolsRefusal
    /// The server's answer, shown if the retry without tools is refused as well.
    let error: ParleyError
}

/// Whether an error answer refuses the request's `tools`. What is remembered about it lives in the
/// app (per provider and model), not here: no process-wide state.
enum ToolsSupport {
    /// Being loose is safe: it counts only if the retry without tools is accepted. Never for a
    /// context overflow. Status 400, 404, 422, 500 or 501, because llama.cpp's own refusals are 500s.
    static func refusal(status: Int, body: String) -> ToolsRefusal.Kind? {
        guard [400, 404, 422, 500, 501].contains(status) else { return nil }
        let lower = body.lowercased()
        if ContextBudget.contextLength(fromError: body) != nil
            || lower.contains("context length") || lower.contains("context window") {
            return nil
        }
        let definitions = ["failed to parse tools", "json schema error at"]
        if definitions.contains(where: lower.contains) { return .definitions }
        let unsupported = [
            "does not support tools", "doesn't support tools",                  // Ollama
            "tools param requires", "unable to generate parser",                // llama.cpp
            "tool choice requires", "tool-call-parser",                         // vLLM
            "support tool use", "tool use is not supported", "tools is not supported", "tools are not supported",
            "function calling is not", "unrecognized request argument supplied: tools", "unknown parameter: 'tools'",
        ]
        if unsupported.contains(where: lower.contains) { return .unsupported }
        if let object = JSONValue(jsonText: body), object["error"]?["param"]?.stringValue == "tools" { return .unsupported }
        return nil
    }

    /// The server's own words: `error.message` when the body is that JSON, else the body.
    static func message(body: String) -> String {
        if let data = body.data(using: .utf8),
           let root = JSONValue.parsed(data) as? [String: Any], let error = root["error"] {
            return ChunkParser.errorMessage(from: error)
        }
        return body
    }
}

/// Never follows HTTP redirects, so requests (and their bodies) only ever reach the configured endpoint.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
