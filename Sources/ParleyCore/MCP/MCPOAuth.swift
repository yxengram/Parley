import CryptoKit
import Darwin
import Foundation

// OAuth for MCP over HTTP, the parts that touch nothing: parsing a challenge, deciding which hosts may
// be used and what a stored token may be sent to, building URLs. See "MCP sign-in" in DESIGN.md.

/// Fixed text only: what lands here can reach `MCPError.summary`, and so a saved conversation.
/// A server's words appear only as a checked error code, or as a host Parley parsed itself.
public enum MCPOAuthFailure: Error, Equatable, Sendable {
    case staticAuthorization
    case urlHasCredentials
    case insecureServer
    case notProtected
    case badResourceMetadata
    case resourceMismatch
    case hostRefused(String)
    case metadataNotFound
    case issuerMismatch
    case noPKCE
    case clientIDRequired
    case clientMetadataUnsupported
    case clientIssuerChanged
    case registrationRefused
    case portBusy(Int)
    case listenerFailed
    case browserFailed
    case timedOut
    case cancelled
    case responseMismatch
    case denied(String)
    case tokenRefused(String)
    case invalidTokenResponse
    case refreshFailed
    case unreachable

    public var text: String {
        switch self {
        case .staticAuthorization:
            return "This server has a static Authorization header, so it does not use sign-in. Remove the header to sign in."
        case .urlHasCredentials:
            return "This server's URL contains a user name or password, which would reach the sign-in provider. Remove it to sign in."
        case .insecureServer:
            return "Sign-in needs an https server. A token sent over plain http could be read on the way."
        case .notProtected:
            return "This server did not say how to sign in, so it may not need it. Try Connect."
        case .badResourceMetadata:
            return "The server's sign-in information is not valid."
        case .resourceMismatch:
            return "The server's sign-in information is for a different address, so it was not used."
        case .hostRefused(let host):
            return "The sign-in host \(Self.printable(host)) was refused: it must use https, and it may not be on a more local network than the server."
        case .metadataNotFound:
            return "The sign-in provider does not publish its settings."
        case .issuerMismatch:
            return "The sign-in provider's settings name a different provider, so they were not used."
        case .noPKCE:
            return "The sign-in provider does not support PKCE with S256, which Parley requires."
        case .clientIDRequired:
            return "This provider needs a client registered by hand. Enter its Client ID below, then press Sign In."
        case .clientMetadataUnsupported:
            return "This provider does not accept a URL as a Client ID, or the URL has no path."
        case .clientIssuerChanged:
            return "This server now signs in through a different provider. Your Client ID and Client Secret were not sent there. Clear both, or enter the ones for the new provider."
        case .registrationRefused:
            return "The sign-in provider refused to register Parley. Enter a Client ID below if you have one."
        case .portBusy(let port):
            return "Port \(port) on this Mac is in use, so the sign-in answer could not be received."
        case .listenerFailed:
            return "Parley could not listen for the sign-in answer on this Mac."
        case .browserFailed:
            return "The browser could not be opened."
        case .timedOut:
            return "Sign-in was not finished within 5 minutes."
        case .cancelled:
            return "Sign-in was cancelled."
        case .responseMismatch:
            return "The answer came from a different sign-in provider, so it was discarded."
        case .denied(let code):
            return "The sign-in provider refused (\(code))."
        case .tokenRefused(let code):
            return "The sign-in provider did not issue a token (\(code))."
        case .invalidTokenResponse:
            return "The sign-in provider's answer is not valid."
        case .refreshFailed:
            return "The sign-in could not be renewed. Parley will try again on the next use."
        case .unreachable:
            return "The sign-in provider could not be reached."
        }
    }

    /// A host decoded from a server's URL can hold bidi controls or a line break.
    private static func printable(_ host: String) -> String {
        String(String.UnicodeScalarView(host.unicodeScalars.prefix(255).map { (0x21...0x7E).contains($0.value) ? $0 : "?" }))
    }

    /// An OAuth `error` value as shown to the user. Anything else from a server is dropped.
    static func code(_ text: String?) -> String {
        guard let text, (1...64).contains(text.utf8.count),
              text.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E })
        else { return "unknown error" }
        return text
    }
}

/// Bearer parameters of a `WWW-Authenticate` header.
struct MCPOAuthChallenge: Equatable, Sendable {
    var resourceMetadata: String?
    var scope: String?
    var error: String?

    private static let maxHeaderBytes = 16 * 1024

    /// Nil unless the header has a Bearer challenge. Names are case-insensitive; other schemes are
    /// skipped, because several challenges can share one header.
    static func parse(_ header: String?) -> MCPOAuthChallenge? {
        guard let header, header.utf8.count <= maxHeaderBytes else { return nil }
        var found: MCPOAuthChallenge?
        var inBearer = false
        var rest = Substring(header)

        func skipSeparators() {
            while let first = rest.first, first == " " || first == "\t" || first == "," { rest.removeFirst() }
        }
        func readToken() -> Substring {
            let end = rest.firstIndex { $0 == " " || $0 == "\t" || $0 == "," || $0 == "=" } ?? rest.endIndex
            defer { rest = rest[end...] }
            return rest[..<end]
        }
        func readValue() -> String {
            guard rest.first == "\"" else { return String(readToken()) }
            rest.removeFirst()
            var value = ""
            while let character = rest.first {
                rest.removeFirst()
                if character == "\"" { break }
                if character == "\\", let next = rest.first {
                    rest.removeFirst()
                    value.append(next)
                } else {
                    value.append(character)
                }
            }
            return value
        }

        while true {
            skipSeparators()
            guard !rest.isEmpty else { break }
            let token = readToken()
            let afterToken = rest.drop { $0 == " " || $0 == "\t" }
            if afterToken.first == "=", !afterToken.dropFirst().hasPrefix("=") {
                rest = afterToken.dropFirst().drop { $0 == " " || $0 == "\t" }
                let value = readValue()
                guard inBearer else { continue }
                switch token.lowercased() {
                case "resource_metadata": found?.resourceMetadata = value
                case "scope": found?.scope = value
                case "error": found?.error = value
                default: break
                }
            } else {
                if token.isEmpty { rest = rest.dropFirst() }
                // A token68 such as `Basic abc==`: its `=` must not read as a parameter.
                inBearer = token.lowercased() == "bearer"
                if inBearer, found == nil { found = MCPOAuthChallenge() }
            }
        }
        return found
    }

    var isInsufficientScope: Bool { error == "insufficient_scope" }
}

/// How close to this Mac a host is. An authorization server may be no closer than the MCP server
/// that named it, or any public server could make Parley probe the local network.
enum MCPOAuthLocality: Int, Comparable, Codable, Sendable {
    case loopback, local, remote

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum MCPOAuthPolicy {
    /// Lower case, without brackets, zone or trailing dots.
    private static func normalized(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Strictly this Mac. Not `ChatClient.isLocalHost`, which also passes LAN names.
    static func isLoopback(_ host: String) -> Bool {
        locality(ofHost: host) == .loopback
    }

    /// Nil: refused. Numeric forms that a resolver reads as an address (`0x7f.1`, `2130706433`) are
    /// refused rather than read, and so are 0/8, `::`, multicast and broadcast.
    static func locality(ofHost host: String) -> MCPOAuthLocality? {
        let name = normalized(host)
        guard !name.isEmpty else { return nil }
        if name == "localhost" || name.hasSuffix(".localhost") { return .loopback }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return locality(ofIPv4: withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            return locality(ofIPv6: withUnsafeBytes(of: v6) { Array($0) })
        }
        if inet_aton(name, &v4) == 1 { return nil }
        for suffix in [".local", ".internal", ".lan", ".home.arpa", ".intranet"] where name.hasSuffix(suffix) {
            return .local
        }
        return name.contains(".") ? .remote : .local
    }

    static func locality(ofIPv4 b: [UInt8]) -> MCPOAuthLocality? {
        guard b.count == 4 else { return nil }
        switch (b[0], b[1]) {
        case (0, _), (224...255, _): return nil
        case (127, _): return .loopback
        // 198.18.0.0/15 stays public: it is the default fake-IP range of Clash, Surge and the like, so
        // on such a Mac ordinary public names resolve there, and calling it local would refuse them.
        case (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return .local
        case (192, 0) where b[2] == 0: return .local
        default: return .remote
        }
    }

    static func locality(ofIPv6 b: [UInt8]) -> MCPOAuthLocality? {
        guard b.count == 16 else { return nil }
        let leadingZeros = b.prefix(15).allSatisfy { $0 == 0 }
        if leadingZeros, b[15] == 0 { return nil }
        if leadingZeros, b[15] == 1 { return .loopback }
        // An IPv4 address in an IPv6 form is that IPv4 address, or wrapping it would get past the rules
        // above: mapped, IPv4-compatible, NAT64 and 6to4.
        if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return locality(ofIPv4: Array(b[12...])) }
        if b.prefix(12).allSatisfy({ $0 == 0 }) { return locality(ofIPv4: Array(b[12...])) }
        if b.prefix(4) == [0x00, 0x64, 0xFF, 0x9B], b[4..<12].allSatisfy({ $0 == 0 }) { return locality(ofIPv4: Array(b[12...])) }
        if b[0] == 0x20, b[1] == 0x02 { return locality(ofIPv4: Array(b[2...5])) }
        if b[0] == 0xFF { return nil }
        if b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) { return .local }
        // Documentation and discard prefixes: nothing public is ever there.
        if b.prefix(4) == [0x20, 0x01, 0x0D, 0xB8] || (b[0] == 0x01 && b[1..<8].allSatisfy({ $0 == 0 })) { return .local }
        return .remote
    }

    /// The closest of `addresses`, or nil if any is refused. For a host about to be contacted: one
    /// private address among public ones is enough to refuse it.
    static func closest(_ addresses: [MCPOAuthLocality?]) -> MCPOAuthLocality?? {
        guard !addresses.isEmpty else { return .some(.none) }
        if addresses.contains(where: { $0 == nil }) { return nil }
        return .some(addresses.compactMap { $0 }.min())
    }

    /// How close an MCP server counts as being, for the floor it sets: the farthest of its addresses.
    /// Taking the closest would let a public server lower its own floor by publishing one private
    /// address beside its real one. A dotted name's class is only a guess, used when nothing
    /// resolved: `box.tailnet.ts.net` reads as remote and is on the LAN, and an intranet or Tailscale
    /// server must be able to reach its own well-known addresses. A refused name stays remote.
    static func floor(named: MCPOAuthLocality?, addresses: [MCPOAuthLocality?]) -> MCPOAuthLocality {
        guard let named else { return .remote }
        return addresses.compactMap { $0 }.max() ?? named
    }

    /// The MCP server may receive a token at all: https, or this Mac.
    static func serverMaySignIn(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return scheme == "https" || (scheme == "http" && isLoopback(host))
    }

    /// An authorization server URL or endpoint: https, or plain http when both it and the MCP server
    /// are on this Mac, the only case a mock can reach. A URL from a server is opened in the browser,
    /// so nothing but these two schemes may pass.
    static func allows(endpoint url: URL, server: URL, floor: MCPOAuthLocality) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host,
              let locality = locality(ofHost: host), locality >= floor else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && locality == .loopback && server.host.map(isLoopback) == true
    }

    /// Host and port as the sheet compares and shows them: another port is another service.
    static func authority(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let standard = url.scheme?.lowercased() == "https" ? 443 : 80
        if let port = url.port, port != standard { return "\(host):\(port)" }
        return host
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func parts(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let left = parts(a), let right = parts(b) else { return false }
        return left == right
    }
}

/// The `resource` value: RFC 9728's is compared, RFC 8707's is sent.
enum MCPOAuthResource {
    /// Same origin, and the metadata's path is the server's path or a whole-segment prefix of it: a
    /// root document names the origin. One trailing slash and host case do not matter. A query must
    /// match if the metadata has one. Also decides whether a stored token may go to the URL now.
    static func matches(_ resource: String, server: URL) -> Bool {
        guard let parsed = URLComponents(string: resource), parsed.fragment == nil, parsed.user == nil, parsed.password == nil,
              let resourceURL = parsed.url, MCPOAuthPolicy.sameOrigin(resourceURL, server),
              let serverParts = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return false }
        if let query = parsed.percentEncodedQuery, query != serverParts.percentEncodedQuery { return false }
        func trimmed(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
        let wanted = trimmed(parsed.percentEncodedPath)
        let actual = trimmed(serverParts.percentEncodedPath)
        return wanted == actual || wanted.isEmpty || actual.hasPrefix(wanted + "/")
    }
}

/// URLs the spec has clients build.
enum MCPOAuthDiscovery {
    private static func origin(_ url: URL) -> URLComponents? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        parts.path = ""
        return parts
    }

    private static func trimmedPath(_ url: URL) -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func url(_ base: URLComponents, _ path: String) -> URL? {
        var parts = base
        parts.percentEncodedPath = path
        return parts.url
    }

    /// Path-inserted first, when the server has a path, then the root.
    static func resourceMetadataURLs(server: URL) -> [URL] {
        guard let base = origin(server) else { return [] }
        let path = trimmedPath(server)
        let suffix = "/.well-known/oauth-protected-resource"
        return (path.isEmpty ? [suffix] : [suffix + path, suffix]).compactMap { url(base, $0) }
    }

    /// The order in "Authorization Server Metadata Discovery". `issuer` is used as written.
    static func authorizationServerURLs(issuer: URL) -> [URL] {
        guard let base = origin(issuer) else { return [] }
        let path = trimmedPath(issuer)
        let oauth = "/.well-known/oauth-authorization-server"
        let openID = "/.well-known/openid-configuration"
        let paths = path.isEmpty ? [oauth, openID] : [oauth + path, openID + path, path + openID]
        return paths.compactMap { url(base, $0) }
    }
}

enum MCPOAuthScopes {
    /// Tokens in the RFC 6749 scope alphabet, in order, without repeats: a scope comes from a server
    /// and ends up on the sheet and in a URL.
    static func split(_ text: String?) -> [String] {
        guard let text else { return [] }
        return unique(text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init))
    }

    static func unique(_ scopes: [String]) -> [String] {
        var seen: Set<String> = []
        return scopes.filter { scope in
            let legal = !scope.isEmpty && scope.utf8.allSatisfy { $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0) }
            return legal && seen.insert(scope).inserted
        }
    }

    /// Challenge, else what the resource metadata supports; then what was requested before, so a
    /// step-up keeps what the server already allowed.
    static func requested(challenge: [String], supported: [String], previous: [String]) -> [String] {
        unique(previous + (challenge.isEmpty ? supported : challenge))
    }
}

enum MCPOAuthPKCE {
    static func randomValue() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MCPOAuthForm {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Sorted, so a request is the same on every run.
    static func encode(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
    }

    /// `client_secret_basic`: both parts are form-encoded first (RFC 6749 2.3.1).
    static func basicAuthorization(clientID: String, secret: String) -> String {
        "Basic " + Data("\(escape(clientID)):\(escape(secret))".utf8).base64EncodedString()
    }
}

/// The RFC 9207 table, applied before anything in an authorization response is read.
enum MCPOAuthIssuerCheck {
    /// `supported` is the metadata's `authorization_response_iss_parameter_supported`. Plain string
    /// comparison, with no normalizing of any kind.
    static func accepts(iss: String?, recorded: String, supported: Bool) -> Bool {
        guard let iss else { return !supported }
        return iss == recorded
    }
}

/// Removes the token a request carried from what came back: a proxy or debug handler that echoes
/// request headers would otherwise put it into a tool result, and so into a saved conversation and
/// a request to the model's provider.
struct MCPTokenScrubber: Sendable {
    let token: String?

    static let replacement = "[token removed]"

    /// For text a parser already decoded.
    func clean(_ text: String) -> String {
        guard let token, !token.isEmpty, text.contains(token) else { return text }
        return text.replacingOccurrences(of: token, with: Self.replacement)
    }

    /// For text nothing decoded, such as an error body. RFC 6750 tokens may hold `/`, `+` and `=`, and
    /// an encoder can write those as `\/`, `\u002B` or `%2B`, so matching is by character.
    func cleanRaw(_ text: String) -> String {
        guard let token, !token.isEmpty, let pattern = rawPattern(token) else { return clean(text) }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: Self.replacement))
    }

    /// Before an error body is shortened, or a token cut in two would escape every match.
    func cleanRaw(_ data: Data) -> Data {
        guard token != nil else { return data }
        return Data(cleanRaw(String(decoding: data, as: UTF8.self)).utf8)
    }

    private func rawPattern(_ token: String) -> NSRegularExpression? {
        var pattern = ""
        for scalar in token.unicodeScalars {
            let literal = NSRegularExpression.escapedPattern(for: String(scalar))
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value > 0x7F {
                pattern += literal
            } else {
                let hex = String(format: "%02X", scalar.value)
                let lower = hex.lowercased()
                pattern += "(?:\\\\?\(literal)|\\\\u00(?:\(hex)|\(lower))|%(?:\(hex)|\(lower)))"
            }
        }
        return try? NSRegularExpression(pattern: pattern)
    }

    func clean(_ value: JSONValue) -> JSONValue {
        guard token != nil else { return value }
        switch value {
        case .string(let text): return .string(clean(text))
        case .array(let items): return .array(items.map(clean))
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, item) in fields { out[clean(key)] = clean(item) }
            return .object(out)
        default: return value
        }
    }

    func clean(_ response: MCPResponse) -> MCPResponse {
        guard token != nil else { return response }
        return MCPResponse(result: response.result.map(clean), error: response.error.map(clean))
    }

    func clean(_ error: MCPRPCError) -> MCPRPCError {
        MCPRPCError(code: error.code, message: clean(error.message), data: error.data.map(clean))
    }
}
