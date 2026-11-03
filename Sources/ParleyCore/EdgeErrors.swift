import Foundation

// Error answers that come from something in front of the server rather than from the server:
// Cloudflare's edge (a Cloudflare Tunnel or a proxied DNS record), and HTML error pages in general.
//
// Behind Cloudflare every response carries `server: cloudflare` and a `cf-ray` header, the
// origin's own JSON errors included (Strata's 401, its context overflow, its busy 429s). So the
// headers alone never mark an error as Cloudflare's: it also needs a status only Cloudflare sends
// (520–530), a challenge (`cf-mitigated: challenge`), Cloudflare's error-page markers in a body that
// is not JSON, or a redirect to Cloudflare Access.
//
// ParleyError.http stores what is built here as its body, so a stored error stays the usual
// "HTTP <status>: <body>" text (older Parley versions and old conversation files read the same
// way) while raw HTML never reaches a conversation file or the UI.

/// A Cloudflare-generated error, reduced to what the UI needs.
public struct CloudflareError: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// 524: the origin sent nothing for 100 seconds.
        case timeout
        /// 530 / error 1033 (and tunnel wording): the tunnel has no connected cloudflared.
        case tunnelDown
        /// 520–523 and edge 502/504: Cloudflare could not get an answer from the origin.
        case originUnreachable
        /// 525/526: the TLS connection from Cloudflare to the origin failed.
        case originTLS
        /// A browser challenge or a firewall block (WAF, Bot Fight Mode, error 1020).
        case challenge
        /// Cloudflare's own rate limiting (error 1015).
        case rateLimited
        /// A redirect to Cloudflare Access's sign-in page.
        case access
        case other
    }

    public var status: Int
    /// Cloudflare's error code: 1033, 1015, 1020…, or the 52x status itself.
    public var code: Int?
    /// The page's short title ("A timeout occurred"), without the host and "Cloudflare" parts.
    public var title: String?
    public var rayID: String?
    /// Access only: the sign-in host the redirect pointed at (never its query).
    public var accessHost: String?
    public var isChallenge = false

    public init(status: Int, code: Int? = nil, title: String? = nil, rayID: String? = nil,
                accessHost: String? = nil, isChallenge: Bool = false) {
        self.status = status
        self.code = code
        self.title = title
        self.rayID = rayID
        self.accessHost = accessHost
        self.isChallenge = isChallenge
    }

    public var kind: Kind {
        if accessHost != nil { return .access }
        let code = self.code ?? status
        if isChallenge || [1006, 1007, 1008, 1009, 1010, 1012, 1020].contains(code) { return .challenge }
        if code == 1015 || status == 429 { return .rateLimited }
        if code == 1033 || status == 530 || Self.mentionsTunnel(title) { return .tunnelDown }
        switch code {
        case 524: return .timeout
        case 525, 526: return .originTLS
        case 520, 521, 522, 523, 502, 504: return .originUnreachable
        default: return status == 524 ? .timeout : .other
        }
    }

    private static func mentionsTunnel(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return t.contains("argo tunnel") || t.contains("cloudflare tunnel") || t.contains("cloudflared")
    }

    // MARK: The stored line

    static let prefix = "Cloudflare "
    private static let raySeparator = " · Ray ID "
    private static let accessPrefix = "Cloudflare Access sign-in at "
    private static let accessSuffix = " (redirect not followed)"

    /// One line for ParleyError.http's body, e.g. "Cloudflare error 1033: Cloudflare Tunnel error · Ray ID 8f1a…".
    public var summary: String {
        if let accessHost { return Self.accessPrefix + accessHost + Self.accessSuffix }
        var line = isChallenge ? "Cloudflare challenge" : "Cloudflare error \(code ?? status)"
        if let title, !title.isEmpty { line += ": " + title }
        if let rayID { line += Self.raySeparator + rayID }
        return line
    }

    /// Reads a stored body: the summary line above, or (from conversations saved before Parley
    /// recognized Cloudflare) the raw error page or Cloudflare's plain "error code: 1033".
    public static func parse(status: Int, body: String) -> CloudflareError? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(accessPrefix) {
            let host = trimmed.dropFirst(accessPrefix.count).prefix { !$0.isWhitespace }
            return CloudflareError(status: status, accessHost: String(host))
        }
        if trimmed.hasPrefix("Cloudflare challenge") || trimmed.hasPrefix("Cloudflare error ") {
            var rest = Substring(trimmed)
            var ray: String?
            if let r = rest.range(of: raySeparator) {
                ray = String(rest[r.upperBound...])
                rest = rest[..<r.lowerBound]
            }
            let challenge = rest.hasPrefix("Cloudflare challenge")
            rest = rest.dropFirst(challenge ? "Cloudflare challenge".count : "Cloudflare error ".count)
            var code: Int?
            if !challenge {
                let digits = rest.prefix { $0.isNumber }
                code = Int(digits)
                rest = rest.dropFirst(digits.count)
            }
            if rest.hasPrefix(": ") { rest = rest.dropFirst(2) }
            return CloudflareError(status: status, code: code, title: rest.isEmpty ? nil : String(rest),
                                   rayID: ray, isChallenge: challenge)
        }
        return fromBody(status: status, text: trimmed, headers: [:], stored: true)
    }

    // MARK: Detection

    /// A live response: nil unless Cloudflare itself produced it (see the file header).
    static func detect(status: Int, headers: [String: String], body: Data) -> CloudflareError? {
        if (300..<400).contains(status), let location = headers["location"],
           let host = URLComponents(string: location)?.host?.lowercased(),
           host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com") {
            return CloudflareError(status: status, rayID: headers["cf-ray"], accessHost: host)
        }
        let text = String(decoding: body.prefix(256 * 1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return fromBody(status: status, text: text, headers: headers, stored: false)
    }

    /// `stored`: a body read back from a conversation, whose headers were not kept.
    private static func fromBody(status: Int, text: String, headers: [String: String], stored: Bool) -> CloudflareError? {
        let viaCloudflare = headers["server"]?.lowercased() == "cloudflare" || headers["cf-ray"] != nil
        let challengeHeader = headers["cf-mitigated"]?.lowercased() == "challenge"
        // The origin's JSON passes through unchanged (Strata's errors through the tunnel).
        if !challengeHeader, ResponseText.isJSON(text) { return nil }
        let lower = text.lowercased()
        let html = ResponseText.isHTML(text)
        // Cloudflare's whole answer to API clients is the one line "error code: 1033". Live, it also
        // needs Cloudflare's headers (another server's text may contain such a line).
        let plainCode = (stored ? status >= 400 : viaCloudflare)
            ? wholeMatch(#"error code: (\d{3,4})"#, in: text).flatMap(Int.init) : nil
        // Only Cloudflare's own error pages (their stylesheet sits in the head, so a page stored cut
        // to 2000 characters still has it). Not bare /cdn-cgi/ or challenge-platform: Cloudflare
        // injects its JS detection script (/cdn-cgi/challenge-platform/…) into the origin's pages.
        let pageMarkers = html && (lower.contains("cf-error-details") || lower.contains("cf-wrapper")
            || lower.contains("cloudflare ray id") || lower.contains("cf-error-code")
            || lower.contains("cf_styles-css") || lower.contains("/cdn-cgi/styles/")
            || (lower.contains("cloudflare") && lower.contains("ray id")))
        // A browser challenge: the header, or (stored, or without it) the interstitial itself.
        let challengePage = html && (status == 403 || status == 503)
            && (lower.contains("cf_chl_opt") || lower.contains("<title>just a moment"))
        let edgeStatus = (520...530).contains(status)
        // cloudflared answers 502/504 with an empty body when it cannot reach the origin.
        let emptyEdgeGateway = viaCloudflare && (status == 502 || status == 504) && text.isEmpty
        guard challengeHeader || challengePage || pageMarkers || plainCode != nil
                || (viaCloudflare && edgeStatus) || emptyEdgeGateway else { return nil }

        var error = CloudflareError(status: status, rayID: headers["cf-ray"])
        error.isChallenge = challengeHeader || challengePage
        error.code = plainCode
            ?? firstMatch(#"cf-error-code[^>]*>\s*(\d{3,4})\s*<"#, in: text).flatMap(Int.init)
            ?? firstMatch(#"Error code\s*(?:<[^>]*>\s*)*(\d{3,4})"#, in: text).flatMap(Int.init)
            ?? firstMatch(#">\s*Error\s*(?:<[^>]*>\s*)*(\d{4})\s*<"#, in: text).flatMap(Int.init)
            ?? (error.isChallenge ? nil : status)
        if error.rayID == nil {
            error.rayID = firstMatch(#"Ray ID:?\s*(?:<[^>]*>\s*)*([0-9a-fA-F]{16})"#, in: text)
        }
        if html { error.title = pageTitle(text, code: error.code) }
        return error
    }

    /// "strata.example.com | 524: A timeout occurred" → "A timeout occurred";
    /// "Cloudflare Tunnel error | strata.example.com | Cloudflare" → "Cloudflare Tunnel error".
    private static func pageTitle(_ html: String, code: Int?) -> String? {
        guard let raw = ResponseText.htmlTitle(html) else { return nil }
        let parts = raw.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        let useful = parts.filter { part in
            !part.isEmpty && part.lowercased() != "cloudflare" && !(part.contains(".") && !part.contains(" "))
        }
        guard var title = useful.first ?? parts.first else { return nil }
        if let code, title.hasPrefix("\(code): ") { title = String(title.dropFirst("\(code): ".count)) }
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    /// Group 1 when `pattern` matches the whole of `text`.
    static func wholeMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// What a non-2xx response is stored as (ParleyError.http's body).
public enum ResponseText {
    static let maxChars = 2000

    static func errorBody(status: Int, response: HTTPURLResponse?, data: Data) -> String {
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        if let cloudflare = CloudflareError.detect(status: status, headers: headers, body: data) {
            return cloudflare.summary
        }
        let text = String(decoding: data, as: UTF8.self)
        // A refused redirect (ChatClient never follows them): where it pointed, without the query.
        if (300..<400).contains(status), let location = headers["location"] {
            return redirectLine(location, relativeTo: response?.url) ?? truncated(text)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON first: a server's JSON message may quote markup ("<title>" in a rejected input).
        if !isJSON(trimmed), isHTML(trimmed) || headers["content-type"]?.lowercased().contains("text/html") == true {
            return htmlSummary(trimmed)
        }
        return truncated(text)
    }

    static func truncated(_ text: String) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) : text
    }

    /// "Redirect to https://host/path (not followed)".
    static func redirectLine(_ location: String, relativeTo base: URL?) -> String? {
        guard let url = URL(string: location, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let clean = components.string else { return nil }
        return redirectPrefix + clean + redirectSuffix
    }

    static let redirectPrefix = "Redirect to "
    static let redirectSuffix = " (not followed)"

    /// The target of a stored `redirectLine`.
    public static func redirectTarget(_ body: String) -> URL? {
        guard body.hasPrefix(redirectPrefix), body.hasSuffix(redirectSuffix) else { return nil }
        return URL(string: String(body.dropFirst(redirectPrefix.count).dropLast(redirectSuffix.count)))
    }

    /// An HTML page (public for the app's rendering of older stored errors).
    public static func isHTMLPage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isJSON(trimmed) && isHTML(trimmed)
    }

    static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    static func isHTML(_ text: String) -> Bool {
        let head = text.prefix(512).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<!--")
            || head.contains("<head") || head.contains("<body") || head.contains("<title")
    }

    /// The page's title (or first heading) as one short line, "HTML page" when it has neither.
    public static func htmlSummary(_ html: String) -> String {
        if let title = htmlTitle(html) { return String(title.prefix(200)) }
        if let h1 = CloudflareError.firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: html.replacingOccurrences(of: "\n", with: " ")) {
            let text = plainText(h1)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return "HTML page"
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let raw = CloudflareError.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html) else { return nil }
        let text = plainText(raw)
        return text.isEmpty ? nil : text
    }

    /// Tags removed, the common entities decoded, whitespace collapsed.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                ("&#039;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&middot;", "·"), ("&hellip;", "…")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A stream that broke after the server had started answering (HTTP 200 received).
public enum StreamInterruption {
    static let base = "The connection closed before the reply finished"
    static let cloudflareMark = " (through Cloudflare)"

    /// The text stored as `ParleyError.api(…)`: what broke and, for a transport error, its description.
    static func message(underlying: String?, viaCloudflare: Bool) -> String {
        base + (viaCloudflare ? cloudflareMark : "") + (underlying.map { ": " + $0 } ?? ".")
    }

    /// Recognizes `message(…)` inside a stored error (with or without "API error: ").
    public static func parse(_ text: String) -> (viaCloudflare: Bool, underlying: String?)? {
        var rest = Substring(text)
        if rest.hasPrefix("API error: ") { rest = rest.dropFirst("API error: ".count) }
        guard rest.hasPrefix(base) else { return nil }
        rest = rest.dropFirst(base.count)
        let cloudflare = rest.hasPrefix(cloudflareMark)
        if cloudflare { rest = rest.dropFirst(cloudflareMark.count) }
        if rest.hasPrefix(": ") {
            let underlying = rest.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return (cloudflare, underlying.isEmpty ? nil : underlying)
        }
        return (cloudflare, nil)
    }
}
