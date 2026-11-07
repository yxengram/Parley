import Darwin
import Foundation

/// The one-shot receiver of an authorization response: `http://127.0.0.1:<port>/callback`, bound to
/// the loopback interface only. POSIX sockets, because NWListener cannot combine a required local
/// address with an ephemeral port. Any page in any browser can reach this port, so a request counts
/// only with the exact path, this listener's own Host and the right `state`. Anything else gets a
/// 400 and leaves it listening, so a stray request cannot end a sign-in.
final class MCPOAuthLoopback: @unchecked Sendable {
    static let path = "/callback"
    private static let maxRequestBytes = 8 * 1024

    let port: Int
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "parley.mcp.oauth.loopback")
    private let source: DispatchSourceRead

    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var state: String?
    private var isClosed = false
    /// One request's whole budget, however slowly it arrives.
    private static let requestTimeout: TimeInterval = 2

    var redirectURI: String { "http://127.0.0.1:\(port)\(Self.path)" }

    /// `port` 0 picks a free one. Throws `.portBusy` for a port that is taken.
    init(port requested: Int) throws {
        // The value can come from storage, and an out-of-range port must not trap.
        guard let portNumber = UInt16(exactly: requested) else { throw MCPOAuthFailure.listenerFailed }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPOAuthFailure.listenerFailed }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = portNumber.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        // Non-blocking: a connection reset between the read event and accept must not block here.
        guard bound, listen(fd, 8) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let reason = errno
            Darwin.close(fd)
            throw reason == EADDRINUSE ? MCPOAuthFailure.portBusy(requested) : MCPOAuthFailure.listenerFailed
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit { close() }

    func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        if !wasClosed { source.cancel() }
    }

    /// Before the browser opens: a provider with a live session can answer at once.
    func expect(state: String) {
        lock.withLock { self.state = state }
    }

    /// The query of the matching request. Ends on `timeout`, or when the calling Task is cancelled.
    func callback(timeout: TimeInterval) async throws -> [String: String] {
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(MCPOAuthFailure.timedOut)) }
        // Not on `queue`, which a slow client can hold for a moment.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(MCPOAuthFailure.cancelled))
        }
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    private func acceptOne() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        // Accepted sockets inherit O_NONBLOCK. A local program that connects and sends nothing, or
        // one byte at a time, must not hold this up.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var limit = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard let request = readRequest(client) else {
            reply(client, status: "400 Bad Request", body: Self.refusedPage)
            return
        }
        let expected = lock.withLock { state }
        guard let query = Self.matchingQuery(request, host: "127.0.0.1:\(port)", state: expected) else {
            reply(client, status: "400 Bad Request", body: Self.refusedPage)
            return
        }
        reply(client, status: "200 OK", body: Self.donePage)
        finish(.success(query))
    }

    private func readRequest(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while data.count <= Self.maxRequestBytes, Date() < deadline {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer[0..<count])
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    /// The query, if this is the one request that counts.
    static func matchingQuery(_ request: String, host: String, state: String?) -> [String: String]? {
        let lines = request.components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ")
        guard words.count == 3, words[0] == "GET", let state,
              let target = URLComponents(string: "http://\(host)\(words[1])"), target.path == path else { return nil }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() == host else { return nil }
        var query: [String: String] = [:]
        for item in target.queryItems ?? [] {
            // A repeated parameter is not a response this client produced.
            guard query[item.name] == nil else { return nil }
            query[item.name] = item.value ?? ""
        }
        return query["state"] == state ? query : nil
    }

    private func reply(_ client: Int32, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\n\r\n"
        let bytes = Array((head + body).utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sent += count
        }
    }

    private static let donePage = "<!doctype html><title>Parley</title><p>You can close this tab and return to Parley.</p>"
    private static let refusedPage = "<!doctype html><title>Parley</title><p>This request was not accepted.</p>"
}
