import Darwin
import Foundation

/// A request's redirect refusal, and where it really went.
private final class MCPOAuthTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?

    /// Where the connection went. Nil through a proxy, whose address says nothing about the target.
    var remoteAddress: String? { lock.withLock { address } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let last = metrics.transactionMetrics.last
        lock.withLock { address = last?.isProxyConnection == true ? nil : last?.remoteAddress }
    }
}

/// Every OAuth request but the browser's. Same rules as the transport: ephemeral, no cookies, no
/// credential store, redirects refused. It never carries the server's static headers. Each request
/// checks where its host resolves first, and where the connection really went before the answer is
/// used. DNS rebinding is made harder by this, not impossible: the two checks and the connection are
/// three lookups an attacker's name server can answer differently.
final class MCPOAuthHTTP: @unchecked Sendable {
    struct Reply {
        var status: Int
        var data: Data
    }

    static let maxBodyBytes = 1024 * 1024
    private static let timeout: TimeInterval = 20

    private let session: URLSession

    init() {
        session = URLSession(configuration: ChatClient.makeConfiguration(), delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func get(_ url: URL, floor: MCPOAuthLocality) async throws -> Reply {
        try await perform(URLRequest(url: url), floor: floor, checksAddress: true)
    }

    /// `form` encoded as `application/x-www-form-urlencoded`.
    func post(_ url: URL, form: [String: String], authorization: String? = nil, floor: MCPOAuthLocality) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(MCPOAuthForm.encode(form).utf8)
        // Only the token endpoint gets this form. Its answer is never dropped: by then the provider
        // has spent the refresh token, and the only copy of the new one is in this answer.
        return try await perform(request, floor: floor, checksAddress: false)
    }

    func post(_ url: URL, json: JSONValue, floor: MCPOAuthLocality) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json.sortedJSONData
        return try await perform(request, floor: floor, checksAddress: true)
    }

    private func perform(_ original: URLRequest, floor: MCPOAuthLocality, checksAddress: Bool) async throws -> Reply {
        var request = original
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let host = request.url?.host else { throw MCPOAuthFailure.unreachable }
        try await Self.check(host: host, floor: floor)
        let delegate = MCPOAuthTaskDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBodyBytes { throw MCPOAuthFailure.invalidTokenResponse }
            }
            if checksAddress, let address = delegate.remoteAddress, !Self.addressIsAllowed(address, floor: floor) {
                throw MCPOAuthFailure.hostRefused(host)
            }
            return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MCPOAuthFailure.unreachable
        }
    }

    /// `remoteAddress` as URLSession reports it: an address, with a port for IPv6 in brackets.
    static func addressIsAllowed(_ address: String, floor: MCPOAuthLocality) -> Bool {
        var host = address
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
        guard let locality = MCPOAuthPolicy.locality(ofHost: host) else { return false }
        return locality >= floor
    }

    /// How close `host` really is, by every address it resolves to. A name that does not resolve
    /// keeps what its text says, and fails later when the connection does.
    static func resolvedLocality(of host: String) async -> MCPOAuthLocality? {
        guard let named = MCPOAuthPolicy.locality(ofHost: host) else { return nil }
        let addresses = await Task.detached { lookUp(host) }.value
        guard let closest = MCPOAuthPolicy.closest(addresses) else { return nil }
        return closest.map { min($0, named) } ?? named
    }

    /// What an MCP server's host sets as the floor for the hosts it names.
    static func floor(forServer host: String) async -> MCPOAuthLocality {
        let addresses = await Task.detached { lookUp(host) }.value
        return MCPOAuthPolicy.floor(named: MCPOAuthPolicy.locality(ofHost: host), addresses: addresses)
    }

    static func check(host: String, floor: MCPOAuthLocality) async throws {
        guard let locality = await resolvedLocality(of: host), locality >= floor else {
            throw MCPOAuthFailure.hostRefused(host)
        }
    }

    private static func lookUp(_ host: String) -> [MCPOAuthLocality?] {
        var name = host
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found: [MCPOAuthLocality?] = []
        var entry = list
        while let current = entry {
            switch current.pointee.ai_family {
            case AF_INET:
                current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    found.append(MCPOAuthPolicy.locality(ofIPv4: withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }))
                }
            case AF_INET6:
                current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    found.append(MCPOAuthPolicy.locality(ofIPv6: withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }))
                }
            default: break
            }
            entry = current.pointee.ai_next
        }
        return found
    }
}

/// The token endpoint, for both grants.
enum MCPOAuthTokenRequest {
    struct Answer {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: TimeInterval?
    }

    /// `invalidGrant` and `invalidClient` change what is kept, so they stand apart from other refusals.
    enum Refusal: Error, Equatable {
        case invalidGrant, invalidClient
        case other(String)
        case transient
    }

    static func send(_ form: [String: String], to endpoint: URL, clientID: String, secret: String?, method: String,
                     http: MCPOAuthHTTP, floor: MCPOAuthLocality) async throws -> Answer {
        var fields = form
        var authorization: String?
        fields["client_id"] = clientID
        if let secret, !secret.isEmpty {
            if method == "client_secret_post" {
                fields["client_secret"] = secret
            } else {
                authorization = MCPOAuthForm.basicAuthorization(clientID: clientID, secret: secret)
            }
        }
        let reply: MCPOAuthHTTP.Reply
        do {
            reply = try await http.post(endpoint, form: fields, authorization: authorization, floor: floor)
        } catch is MCPOAuthFailure {
            throw Refusal.transient
        }
        return try parse(reply)
    }

    /// An `error` field fails at any status: GitHub answers 200 with one.
    static func parse(_ reply: MCPOAuthHTTP.Reply) throws -> Answer {
        let body = JSONValue(jsonData: reply.data)
        if let code = body?["error"]?.stringValue {
            switch code {
            case "invalid_grant": throw Refusal.invalidGrant
            case "invalid_client": throw Refusal.invalidClient
            default: throw Refusal.other(MCPOAuthFailure.code(code))
            }
        }
        if reply.status >= 500 || reply.status == 429 { throw Refusal.transient }
        guard (200..<300).contains(reply.status), let token = body?["access_token"]?.stringValue, !token.isEmpty,
              body?["token_type"]?.stringValue?.lowercased() == "bearer" else {
            throw Refusal.other("invalid response")
        }
        var lifetime: TimeInterval?
        // Some providers send it as a string.
        let seconds = body?["expires_in"]?.intValue ?? body?["expires_in"]?.stringValue.flatMap { Int64($0) }
        if let seconds, seconds > 0 { lifetime = TimeInterval(seconds) }
        return Answer(accessToken: token, refreshToken: body?["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                      expiresIn: lifetime)
    }
}
