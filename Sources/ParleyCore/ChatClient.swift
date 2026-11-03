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
    }
}

public final class ChatClient: @unchecked Sendable {
    public let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let chatURL: URL
    private let modelsURL: URL

    private static let maxErrorBodyChars = 2000

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
            throw ParleyError.http(status: status, body: Self.truncatedBody(data))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
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
    public func streamChat(messages: [Message], options: ChatRequestOptions) -> AsyncThrowingStream<ChatDelta, Error> {
        let request: URLRequest
        do {
            request = try makeChatRequest(messages: messages, options: options)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream<ChatDelta, Error> { continuation in
            // The task holds `self` (and so the session) until the stream ends, even if the
            // caller drops its reference to the client.
            let task = Task {
                do {
                    try await self.runStream(request: request, continuation: continuation)
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

    private func runStream(
        request: URLRequest,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= Self.maxErrorBodyChars * 4 { break }
            }
            throw ParleyError.http(status: status, body: Self.truncatedBody(collected))
        }

        // A server that ignores stream:true answers with one plain JSON completion.
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
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
                    if try Self.emit(decoder.feed(line: line), to: continuation) { return }
                }
                _ = try Self.emit(decoder.finish(), to: continuation)
            } else if let delta = try ChunkParser.parse(text) {
                continuation.yield(delta)
            }
            return
        }

        var decoder = SSEDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if try Self.emit(decoder.feed(line: line), to: continuation) { return }
        }
        try Task.checkCancellation()
        _ = try Self.emit(decoder.finish(), to: continuation)
    }

    /// Parses and yields payloads. Returns true once "[DONE]" is seen.
    private static func emit(
        _ payloads: [String],
        to continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) throws -> Bool {
        for payload in payloads {
            if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return true }
            if let delta = try ChunkParser.parse(payload) {
                continuation.yield(delta)
            }
        }
        return false
    }

    private func makeChatRequest(messages: [Message], options: ChatRequestOptions) throws -> URLRequest {
        let body = Self.buildRequestBody(messages: messages, options: options)
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Adds `missingVersionPathHint` to errors that suggest the wrong endpoint was hit, but only
    /// when the base URL has no path. Other errors pass through unchanged.
    func withPathHint(_ error: Error) -> Error {
        guard baseURLHasNoPath, let parley = error as? ParleyError else { return error }
        switch parley {
        case .api(let message):
            return ParleyError.api(message + " " + Self.missingVersionPathHint)
        case .http(let status, let body) where status == 404 || status == 405:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParleyError.api("Endpoint not found (HTTP \(status))" + (detail.isEmpty ? "." : ": \(detail)") + " " + Self.missingVersionPathHint)
        default:
            return error
        }
    }

    private func applyAuthorization(to request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func truncatedBody(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.count > maxErrorBodyChars ? String(text.prefix(maxErrorBodyChars)) : text
    }

    // MARK: Request body

    /// Pure, for tests. Returns the JSON body dictionary.
    public static func buildRequestBody(messages: [Message], options: ChatRequestOptions) -> [String: Any] {
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
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                apiMessages.append(["role": "assistant", "content": message.content])

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

        var body: [String: Any] = [
            "model": options.model,
            "stream": true,
            "messages": apiMessages,
        ]
        if let t = options.temperature { body["temperature"] = t }
        if let m = options.maxTokens { body["max_tokens"] = m }
        if let r = options.reasoningEffort { body["reasoning_effort"] = r.rawValue }
        return body
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
