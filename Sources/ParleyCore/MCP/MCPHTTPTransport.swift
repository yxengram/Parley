import Foundation

/// Streamable HTTP: every message is a POST to one URL, answered with one JSON object or with an
/// event stream that ends in the response. Same session rules as ChatClient: ephemeral, no cookies,
/// no credential store, and redirects are refused, because a 307 would replay a tool's arguments
/// and the user's tokens to whatever host it names. No OAuth discovery, no .well-known, ever.
final class MCPHTTPTransport: MCPTransport, MCPStoppable, @unchecked Sendable {
    let isHTTP = true
    private let url: URL
    private let userHeaders: [String: String]
    private let session: URLSession
    private let maxMessageBytes: Int
    private let registry: MCPProcessRegistry?

    private let lock = NSLock()
    private var inboundHandler: (@Sendable (MCPInbound) -> Void)?
    private var closedHandler: (@Sendable (Error?) -> Void)?
    /// Legacy: the session the server gave on initialize.
    private var sessionID: String?
    private var protocolVersion: String?
    private var isClosed = false

    /// `url` and `headers` have been through `validated(url:secrets:)`.
    init(url: URL, headers: [String: String], registry: MCPProcessRegistry?, maxMessageBytes: Int = MCPProtocol.maxMessageBytes) {
        self.url = url
        self.userHeaders = headers
        self.registry = registry
        self.maxMessageBytes = maxMessageBytes
        session = URLSession(configuration: ChatClient.makeConfiguration(), delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    static func validated(url text: String, secrets: MCPServerSecrets) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { throw MCPError.invalidURL }
        if let name = secrets.invalidHeaderName { throw MCPError.invalidHeader(name) }
        return url
    }

    deinit {
        session.invalidateAndCancel()
    }

    var onInbound: (@Sendable (MCPInbound) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return inboundHandler }
        set { lock.lock(); defer { lock.unlock() }; inboundHandler = newValue }
    }

    var onClosed: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closedHandler }
        set { lock.lock(); defer { lock.unlock() }; closedHandler = newValue }
    }

    func start() async throws {
        if let registry, !registry.add(self) { throw MCPError.streamEnded }
    }

    func resetSession() {
        lock.lock(); defer { lock.unlock() }
        sessionID = nil
    }

    private func currentSession() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    private func store(session: String?) {
        guard let session, !session.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        sessionID = session
    }

    private func request(_ method: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // MCPClient enforces each request's own timeout; this only must not undercut it.
        request.timeoutInterval = 3600
        // Protocol headers last, so a pasted header cannot replace them.
        for (name, value) in userHeaders { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let sessionID = currentSession() { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        return request
    }

    private func post(_ body: Data, headers: [String: String]) -> URLRequest {
        var request = request("POST", headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    func send(_ message: MCPOutbound) async throws -> MCPResponse {
        try ensureOpen()
        let request = post(MCPWire.encode(message), headers: message.httpHeaders)
        let sentSession = request.value(forHTTPHeaderField: "MCP-Session-Id") != nil
        let (bytes, response) = try await perform(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            let data = try await collect(bytes, limit: ChatClient.maxErrorBodyBytes, failsOverLimit: false)
            if let rejected = rejection(status: status, data: data, sentSession: sentSession) {
                return MCPResponse(result: nil, error: rejected)
            }
            throw failure(status: status, response: http, data: data, sentSession: sentSession)
        }
        store(session: http?.value(forHTTPHeaderField: "MCP-Session-Id"))

        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            return try await readEvents(bytes, id: message.id)
        }
        let data = try await collect(bytes, limit: maxMessageBytes, failsOverLimit: true)
        guard let messages = MCPWire.decode(data) else {
            throw MCPError.invalidResponse("the body is not JSON-RPC")
        }
        guard let answer = answer(to: message.id, in: messages) else {
            throw MCPError.invalidResponse("no response to this request")
        }
        return answer
    }

    /// URLSession's cancellation error means the Task was cancelled, and a connection lost after
    /// the request went out means the request is lost.
    private func perform(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .networkConnectionLost {
            throw MCPError.streamEnded
        }
    }

    /// A JSON-RPC error in an error status: a modern server's 400 or 404. A 404 on a request with
    /// a session is the session's end, whatever its body says.
    private func rejection(status: Int, data: Data, sentSession: Bool) -> MCPRPCError? {
        guard status == 400 || status == 405 || (status == 404 && !sentSession), let messages = MCPWire.decode(data) else { return nil }
        for case .response(_, _, let error?) in messages { return error }
        return nil
    }

    private func failure(status: Int, response: HTTPURLResponse?, data: Data, sentSession: Bool) -> MCPError {
        if status == 401 || status == 403 { return .needsAuthorization(status: status) }
        if (300..<400).contains(status) {
            return .refusedRedirect(ResponseText.errorBody(status: status, response: response, data: data))
        }
        if status == 404 && sentSession { return .sessionExpired }
        return .http(status: status, body: ResponseText.errorBody(status: status, response: response, data: data))
    }

    /// The response to `id`; everything else goes to `onInbound`.
    private func answer(to id: Int?, in messages: [MCPInbound]) -> MCPResponse? {
        var found: MCPResponse?
        for message in messages {
            if case .response(let answered, let result, let error) = message {
                // A rejection with a null id still answers the only request on this connection.
                if answered.intValue.map(Int.init) == id || answered.isNull {
                    found = MCPResponse(result: result, error: error)
                }
            } else {
                onInbound?(message)
            }
        }
        return found
    }

    /// Lines until the response to `id`. The end of the body before it means the request is lost.
    private func readEvents(_ bytes: URLSession.AsyncBytes, id: Int?) async throws -> MCPResponse {
        var decoder = SSEDecoder()
        var line = Data()
        var afterCR = false
        do {
            for try await byte in bytes {
                // SSE lines end in LF, CR or CRLF.
                defer { afterCR = byte == 0x0D }
                if byte == 0x0A, afterCR { continue }
                if byte != 0x0A, byte != 0x0D {
                    line.append(byte)
                    if line.count > maxMessageBytes { throw MCPError.messageTooLarge }
                    continue
                }
                let payloads = decoder.feed(line: String(decoding: line, as: UTF8.self))
                line = Data()
                // An SSE event ends with a blank line, which a data line completes in SSEDecoder.
                if let response = firstAnswer(payloads, id: id) { return response }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MCPError.streamEnded
        }
        try Task.checkCancellation()
        if !line.isEmpty, let response = firstAnswer(decoder.feed(line: String(decoding: line, as: UTF8.self)), id: id) {
            return response
        }
        if let response = firstAnswer(decoder.finish(), id: id) { return response }
        throw MCPError.streamEnded
    }

    private func firstAnswer(_ payloads: [String], id: Int?) -> MCPResponse? {
        for payload in payloads {
            guard let messages = MCPWire.decode(Data(payload.utf8)) else { continue }
            if let response = answer(to: id, in: messages) { return response }
        }
        return nil
    }

    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int, failsOverLimit: Bool) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    if failsOverLimit { throw MCPError.messageTooLarge }
                    break
                }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MCPError.streamEnded
        }
        return data
    }

    func notify(_ message: MCPOutbound) async throws {
        try await post(accepted: MCPWire.encode(message), headers: message.httpHeaders)
    }

    func respond(to id: JSONValue, result: JSONValue?, error: MCPRPCError?, headers: [String: String]) async throws {
        try await post(accepted: MCPWire.encodeResponse(id: id, result: result, error: error), headers: headers)
    }

    /// A POST that expects no answer, normally 202. The status is the answer: a server that never
    /// ends the body must not hold up what comes next.
    private func post(accepted body: Data, headers: [String: String]) async throws {
        try ensureOpen()
        let (bytes, response) = try await perform(post(body, headers: headers))
        bytes.task.cancel()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MCPError.http(status: status, body: "") }
    }

    /// A closed transport sends nothing: a late `notifications/cancelled` or ping reply lands here.
    /// The session stays valid until `deinit`, because a task made on an invalidated session
    /// raises an exception, and no check here could rule out that race.
    private func ensureOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if isClosed { throw MCPError.streamEnded }
    }

    func close(grace: TimeInterval) async {
        registry?.remove(self)
        guard markClosed() else { return }
        for task in await session.allTasks { task.cancel() }
        if let request = deleteRequest() {
            // Best effort, ending the server's session. 405 is allowed.
            _ = try? await session.data(for: request)
        }
    }

    private func markClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { isClosed = true }
        return !isClosed
    }

    private func deleteRequest() -> URLRequest? {
        guard currentSession() != nil else { return nil }
        var request = request("DELETE", headers: protocolHeaders())
        request.timeoutInterval = 5
        return request
    }

    func setProtocolVersion(_ version: String) {
        lock.lock(); defer { lock.unlock() }
        protocolVersion = version
    }

    private func protocolHeaders() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return protocolVersion.map { ["MCP-Protocol-Version": $0] } ?? [:]
    }

    /// At quit: nothing is awaited.
    func stopNow(grace: TimeInterval) {
        guard markClosed() else { return }
        let delete = deleteRequest().map { session.dataTask(with: $0) }
        delete?.resume()
        session.getAllTasks { tasks in
            for task in tasks where task !== delete { task.cancel() }
        }
    }
}
