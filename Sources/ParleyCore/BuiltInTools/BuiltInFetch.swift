import Darwin
import Foundation

/// How a fetch ended, and where the connection went. Three states on purpose: "nothing yet" must not
/// read as "through a proxy", or a request whose metrics never came would skip the check.
private final class FetchTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Metrics: Equatable {
        case pending
        case proxy
        case address(String?)
    }

    private let lock = NSLock()
    private var collected = Metrics.pending

    var metrics: Metrics { lock.withLock { collected } }

    /// BuiltInFetcher follows redirects itself, so that each hop passes every check.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let last = metrics.transactionMetrics.last
        lock.withLock { collected = last?.isProxyConnection == true ? .proxy : .address(last?.remoteAddress) }
    }
}

/// `fetch_url`: one GET to a public address, as text.
///
/// Public addresses only, or the model could probe the LAN, loopback or Tailscale. The host's name
/// and everything it resolves to must be remote before anything is sent, and where the connection
/// really went is checked before any of the answer is used, its status included.
///
/// Known limit, as for OAuth: the check and the connection are separate lookups, so DNS rebinding or
/// a proxy can let the GET reach a LAN host before the second check throws the answer away. The model
/// never receives that answer. A failure there reads the same as any other, though the model can still
/// time a call. A fake-IP proxy answers every name with an address of its own, so behind one neither
/// check can tell a LAN target from a public one. The real defence is the approval card, which shows
/// the address.
///
/// Never runs JavaScript, never loads a sub-resource, never writes to disk, and never carries a
/// cookie, an API key or an MCP header.
struct BuiltInFetcher: Sendable {
    static let maxBodyBytes = 2 * 1024 * 1024
    static let maxRedirects = 5
    private static let requestTimeout: TimeInterval = 30
    /// How long a finished or cut-off request may take to report where it went.
    private static let metricsWait: TimeInterval = 2

    private let floor: MCPOAuthLocality
    private let connectionFloor: MCPOAuthLocality

    /// What the app uses: public addresses. There is no way to lower this outside a test.
    init() { self.init(floor: .remote) }

    /// Tests only, against a mock on loopback. `connectionFloor` differing from `floor` stands in for
    /// a name that looked public and connected somewhere else.
    init(floor: MCPOAuthLocality, connectionFloor: MCPOAuthLocality? = nil) {
        self.floor = floor
        self.connectionFloor = connectionFloor ?? floor
    }

    /// The address as it will be requested: http or https, a host, no userinfo, no fragment.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let written = URL(string: trimmed), var parts = URLComponents(url: written, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil else { return nil }
        // `URL.host` decodes `%`, and IDNA does not apply then: `ex%D0%B0mple.org` would reach the card
        // as a lookalike of example.org, the one line the user is told to read. No real name needs it.
        guard parts.encodedHost?.contains("%") != true else { return nil }
        parts.fragment = nil
        guard let url = parts.url, let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func fetch(_ text: String?) async -> BuiltInAnswer {
        guard let text else { return .error("`url` must be a string.") }
        guard let start = Self.parse(text) else {
            return .error("Only http and https addresses with a plain host and no user name or password can be fetched.")
        }
        // Per call, so no connection outlives its check and none stays open after an answer.
        let session = URLSession(configuration: ChatClient.makeConfiguration())
        defer { session.invalidateAndCancel() }
        do {
            var url = start
            for _ in 0...Self.maxRedirects {
                switch try await hop(url, session: session) {
                case .done(let answer):
                    return answer
                case .redirect(let target):
                    guard MCPOAuthPolicy.sameOrigin(target, url), target.user == nil, target.password == nil else {
                        return .text(Self.redirectText(target))
                    }
                    url = target
                }
            }
            return .error("Too many redirects: stopped after \(Self.maxRedirects).")
        } catch is CancellationError {
            return .cancelled
        } catch let refusal as BuiltInRefusal {
            return .error(refusal.message)
        } catch {
            return .error("The page could not be fetched.")
        }
    }

    private enum Hop {
        case done(BuiltInAnswer)
        case redirect(URL)
    }

    private func hop(_ url: URL, session: URLSession) async throws -> Hop {
        guard let host = url.host else { throw BuiltInRefusal("The address has no host.") }
        try await Self.checkHost(host, floor: floor)
        // A lookup cannot be interrupted, and Stop during one must not still send the GET.
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Parley", forHTTPHeaderField: "User-Agent")
        // Set, or URLSession sends the system's languages, which say something about the user.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html, text/plain, application/json, application/xml, */*;q=0.5", forHTTPHeaderField: "Accept")

        let delegate = FetchTaskDelegate()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        } catch {
            throw await failure(error, delegate: delegate, host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            return .done(.error("The server did not answer with HTTP."))
        }

        let status = http.statusCode
        let type = http.mimeType?.lowercased() ?? ""
        let wanted = (200..<300).contains(status) && Self.isText(type)
        // Read even when the body is not wanted: the task reports where it went only once its bytes
        // have been taken up, and a cancel with none read never does. One byte is enough for that.
        let limit = wanted ? Self.maxBodyBytes : 0
        var body = Data()
        var wasCut = false
        do {
            for try await byte in bytes {
                if body.count == limit {
                    wasCut = true
                    break
                }
                body.append(byte)
            }
        } catch {
            bytes.task.cancel()
            throw await failure(error, delegate: delegate, host: host)
        }
        bytes.task.cancel()
        try Task.checkCancellation()
        // Before anything of the answer is used: a LAN host's status or Location says something too.
        try await checkConnection(delegate, host: host)

        if (300..<400).contains(status), status != 304 {
            guard let location = http.value(forHTTPHeaderField: "Location"), let target = Self.redirectTarget(location, from: url) else {
                return .done(.error("The server answered HTTP \(status) with no usable address."))
            }
            return .redirect(target)
        }
        guard (200..<300).contains(status) else { return .done(.error("The server answered HTTP \(status).")) }
        guard wanted else {
            let length = http.expectedContentLength
            let size = length >= 0 ? "\(length) bytes" : "unknown size"
            return .done(.error("Not a text page: \(type.isEmpty ? "no content type" : type), \(size). Nothing was read."))
        }

        let decoded = Self.decode(body, charset: http.textEncodingName, wasCut: wasCut)
        let isHTML = type == "text/html" || type == "application/xhtml+xml"
        var out = "URL: \(url.absoluteString)\nType: \(type)\n"
        if wasCut { out += "Note: this page is larger than 2 MiB. Only the start was read.\n" }
        return .done(.text(out + "\n" + (isHTML ? HTMLText.plain(decoded) : decoded)))
    }

    /// Shared with `browse_url`, which checks the page's host the same way before anything starts.
    static func checkHost(_ host: String, floor: MCPOAuthLocality, verb: String = "fetched") async throws {
        // The name's own class first: a name it refuses is never looked up, so asking about a
        // `.local` name sends nothing to the network.
        guard let named = MCPOAuthPolicy.locality(ofHost: host), named >= floor else { throw refused(host, verb: verb) }
        guard let resolved = await MCPOAuthHTTP.resolvedLocality(of: host), resolved >= floor else { throw refused(host, verb: verb) }
    }

    private func checkConnection(_ delegate: FetchTaskDelegate, host: String) async throws {
        let deadline = Date().addingTimeInterval(Self.metricsWait)
        while delegate.metrics == .pending, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        switch delegate.metrics {
        case .proxy:
            // A proxy's address says nothing about the target. The first check is all there is.
            return
        case .address(let address?):
            if Self.isNumeric(address), MCPOAuthHTTP.addressIsAllowed(address, floor: connectionFloor) { return }
            throw Self.connectionFailed(host)
        case .address(nil), .pending:
            throw Self.connectionFailed(host)
        }
    }

    /// What a failed request says. Once the GET has gone out, only a connection known to be public
    /// gets the detail: on a rebound name, "refused", "failed" and "timed out" would tell the model
    /// whether a LAN port is open. A name that does not resolve reached nothing, so it keeps its text.
    private func failure(_ error: Error, delegate: FetchTaskDelegate, host: String) async -> Error {
        let detail = Self.mapped(error, host: host)
        if detail is CancellationError { return detail }
        if let code = (error as? URLError)?.code, code == .cannotFindHost || code == .dnsLookupFailed { return detail }
        return (try? await checkConnection(delegate, host: host)) == nil ? Self.connectionFailed(host) : detail
    }

    /// `addressIsAllowed` reads an unrecognized dotted text as a public name. Here that has to mean no.
    private static func isNumeric(_ address: String) -> Bool {
        var host = address
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    private static func connectionFailed(_ host: String) -> BuiltInRefusal {
        BuiltInRefusal("The connection to \(host) failed.")
    }

    static func refused(_ host: String, verb: String = "fetched") -> BuiltInRefusal {
        BuiltInRefusal("\(host) was refused: only public internet addresses can be \(verb), not this computer, the local network or a VPN.")
    }

    private static func redirectTarget(_ location: String, from url: URL) -> URL? {
        guard var parts = URL(string: location, relativeTo: url).flatMap({ URLComponents(url: $0.absoluteURL, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        parts.fragment = nil
        return parts.url
    }

    private static func redirectText(_ target: URL) -> String {
        "The server redirects to \(target.absoluteString). Parley did not follow it, because that is another address. "
            + "To read it, call fetch_url with that address: the user is asked again."
    }

    private static func isText(_ type: String) -> Bool {
        type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml")
            || ["application/json", "application/xml", "application/xhtml+xml"].contains(type)
    }

    /// By the charset header, else UTF-8, where a bad byte becomes U+FFFD. A page's own <meta> is not read.
    static func decode(_ data: Data, charset: String?, wasCut: Bool) -> String {
        if let charset {
            // GB2312 is how GBK pages usually label themselves, and browsers read it as GBK.
            let name = charset.lowercased() == "gb2312" ? "gbk" : charset
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let declared = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                if let text = String(data: data, encoding: declared) { return text }
                // That is all or nothing, and the cap alone can cut a character. Stay in the declared
                // encoding: read as UTF-8, one bad byte would turn the whole page into U+FFFD.
                if declared != .utf8 {
                    if wasCut {
                        for cut in 1...3 where cut < data.count {
                            if let text = String(data: data.dropLast(cut), encoding: declared) { return text }
                        }
                    }
                    return decodeInPieces(data, encoding: declared)
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keeps a bad byte to its own line or text node. `<`, `>` and newline are never part of a character
    /// in these encodings: a trail byte in GBK, Big5, Shift_JIS or EUC is 0x30 or more and not these.
    /// Not NSString's lossy decoding, which on short input loses good text around a bad byte.
    private static func decodeInPieces(_ data: Data, encoding: String.Encoding) -> String {
        var out = ""
        var start = data.startIndex
        func flush(to end: Data.Index) {
            guard start < end else { return }
            out += String(data: data[start..<end], encoding: encoding) ?? "\u{FFFD}"
        }
        for (index, byte) in zip(data.indices, data) where byte == 0x0A || byte == 0x3C || byte == 0x3E {
            flush(to: index)
            out.unicodeScalars.append(Unicode.Scalar(byte))
            start = index + 1
        }
        flush(to: data.endIndex)
        return out
    }

    private static func mapped(_ error: Error, host: String) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return BuiltInRefusal("\(host) did not answer in time.")
        case .cannotFindHost, .dnsLookupFailed: return BuiltInRefusal("\(host) could not be found.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return BuiltInRefusal("The secure connection to \(host) failed.")
        default: return BuiltInRefusal("The connection to \(host) failed.")
        }
    }
}
