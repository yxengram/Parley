import Foundation

// `browse_url`: one page in a private browser that runs its scripts. WebKit has to run in the app, on
// the main thread, so the core only decides: what may be opened, through what gate, what the page may
// do, and what the model is told. The app's `BuiltInPageLoader` does the loading and nothing else.

/// What the app is asked to load. Everything it needs is in here; it decides nothing of its own.
public struct BuiltInBrowseRequest: Sendable, Equatable {
    /// Already parsed by `BuiltInFetcher.parse` and checked against the floor.
    public let url: URL
    /// The loopback CONNECT proxy for this call (`BuiltInBrowseProxy`). Every connection that WebKit
    /// does not keep on loopback goes through it.
    public let proxyPort: UInt16
    /// WebKit content rules, as JSON (`BuiltInBrowsePolicy.contentRules`).
    public let contentRules: String
    public let wantsLinks: Bool
    /// The page's text is cut here, in the page, before it crosses to the app.
    public let maxCharacters: Int
    public let maxLinks: Int
    /// From the first request to `didFinish`. A page that is not done by then is read as it is.
    public let loadTimeout: TimeInterval
    /// After `didFinish`, how long to wait for scripts to stop changing the text.
    public let settleTimeout: TimeInterval
}

public struct BuiltInBrowseLink: Sendable, Equatable {
    public var text: String
    public var url: String

    public init(text: String, url: String) {
        self.text = text
        self.url = url
    }
}

public struct BuiltInBrowsePage: Sendable, Equatable {
    public var finalURL: String
    public var title: String
    public var text: String
    /// The page's text was longer than `maxCharacters`.
    public var textWasCut: Bool
    public var links: [BuiltInBrowseLink]
    /// False when the load timeout came first.
    public var finishedLoading: Bool

    public init(finalURL: String, title: String, text: String, textWasCut: Bool = false,
                links: [BuiltInBrowseLink] = [], finishedLoading: Bool = true) {
        self.finalURL = finalURL
        self.title = title
        self.text = text
        self.textWasCut = textWasCut
        self.links = links
        self.finishedLoading = finishedLoading
    }
}

public enum BuiltInBrowseFailure: Sendable, Equatable {
    case notFound
    case timedOut
    case insecure
    case connection
    /// The page's process stopped (a crash, or it ran out of memory).
    case crashed
    case other
}

public enum BuiltInBrowseOutcome: Sendable, Equatable {
    case page(BuiltInBrowsePage)
    /// The main frame went to another origin, by a redirect or a script. It was stopped there.
    case left(to: URL)
    /// The main frame was not something to show (a download, a PDF, an image). Nothing was saved.
    case notAPage(mimeType: String)
    /// The main frame answered outside 2xx. Not read, as `fetch_url` does not read one.
    case httpError(Int)
    case failed(BuiltInBrowseFailure)
    case cancelled
}

/// The app's side of the bridge. `load` runs one page in a fresh, non-persistent web view and tears
/// it down before it returns, on every path, Task cancellation included.
public protocol BuiltInPageLoader: Sendable {
    func load(_ request: BuiltInBrowseRequest) async -> BuiltInBrowseOutcome
}

/// Decisions with no WebKit in them, so they can be tested here.
public enum BuiltInBrowsePolicy {
    public enum Navigation: Equatable, Sendable {
        case allow
        case cancel
        /// A main-frame navigation to another origin: stop, and tell the model where it wanted to go.
        case leave(URL)
    }

    /// The main frame stays on the origin the user approved. Frames inside it may go to any http(s)
    /// address (each connection still goes through the proxy), or be `about:`, `data:` or `blob:`.
    /// Anything else (`file:`, `mailto:`, an app's own scheme) is cancelled.
    public static func navigation(to target: URL?, isMainFrame: Bool, approved: URL) -> Navigation {
        guard let target, let scheme = target.scheme?.lowercased() else { return .cancel }
        let isWeb = scheme == "http" || scheme == "https"
        if isMainFrame {
            guard isWeb else { return .cancel }
            if MCPOAuthPolicy.sameOrigin(target, approved), target.user == nil, target.password == nil { return .allow }
            guard var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return .cancel }
            parts.fragment = nil
            return parts.url.map(Navigation.leave) ?? .cancel
        }
        return isWeb || ["about", "data", "blob"].contains(scheme) ? .allow : .cancel
    }

    /// A MIME type the main frame may show. Anything WebKit cannot show is a download, which is never
    /// started; PDFs and images would show, but have no text to read.
    public static func showsAsPage(mimeType: String?, canShow: Bool) -> Bool {
        guard canShow else { return false }
        let type = (mimeType ?? "").lowercased()
        return !(type == "application/pdf" || type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/"))
    }

    /// The approved site as the proxy sees a connection: host and port (a CONNECT has no scheme).
    public static func site(of url: URL) -> (host: String, port: UInt16)? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        guard let value = UInt16(exactly: port) else { return nil }
        return (host, value)
    }

    static func isSameSite(host: String, port: UInt16, as site: (host: String, port: UInt16)) -> Bool {
        BuiltInBrowseProxy.normalized(host) == BuiltInBrowseProxy.normalized(site.host) && port == site.port
    }

    /// The text has stopped changing: the last three samples, taken a fixed interval apart, agree.
    public static func isSettled(_ lengths: [Int]) -> Bool {
        lengths.count >= 3 && Set(lengths.suffix(3)).count == 1
    }

    /// WebKit content rules for the page:
    /// - no images, media, fonts, SVG documents, popups or pings (beacons and `<a ping>`): there is
    ///   nothing in them to read, they cost memory, and most trackers are one of them;
    /// - no frames from other sites, which are mostly ads and whose text `innerText` leaves out anyway;
    /// - with `blockingLoopback`, nothing on this Mac: WebKit connects there without asking the proxy.
    ///   All IPv6 literals go too, since `::1` and `::ffff:127.0.0.1` bypass it; a public page that
    ///   names one is rare. `0.0.0.0` reaches this Mac on macOS.
    ///
    /// `alsoBlocking` is for tests, which load their page from loopback and need some other loopback
    /// name to show that a rule holds.
    public static func contentRules(blockingLoopback: Bool, alsoBlocking hosts: [String] = []) -> String {
        var rules: [JSONValue] = [
            rule(".*", types: ["image", "media", "font", "svg-document", "popup", "ping"]),
            rule(".*", types: ["document"], loadType: "third-party"),
        ]
        var blockedHosts = hosts.map(NSRegularExpression.escapedPattern(for:))
        if blockingLoopback {
            // Numeric only: WebKit writes every IPv4 form as dotted decimal, and `0.gravatar.com` is a name.
            blockedHosts += ["localhost", "[^/:@]*\\.localhost", "127\\.[0-9.]*", "0\\.[0-9.]*", "\\[[^/@]*\\]"]
        }
        for host in blockedHosts {
            // Canonical URLs always have ":" or "/" after the host. Userinfo is allowed for, so
            // `http://a@localhost/` is caught too.
            rules.append(rule("^[a-z][a-z0-9+.-]*://([^/]*@)?\(host)\\.?[:/]"))
        }
        return JSONValue.array(rules).sortedJSONText
    }

    private static func rule(_ filter: String, types: [String]? = nil, loadType: String? = nil) -> JSONValue {
        var trigger: [String: JSONValue] = ["url-filter": .string(filter)]
        if let types { trigger["resource-type"] = .array(types.map(JSONValue.string)) }
        if let loadType { trigger["load-type"] = .array([.string(loadType)]) }
        return .object(["trigger": .object(trigger), "action": .object(["type": .string("block")])])
    }

    /// The request line and headers of one proxy request, up to the blank line. Only CONNECT to a
    /// host and a port is accepted: WebKit tunnels plain http that way too.
    struct ConnectRequest: Equatable {
        var host: String
        var port: UInt16
    }

    static func parseConnect<Bytes: Collection>(_ header: Bytes) -> ConnectRequest? where Bytes.Element == UInt8 {
        guard let text = String(bytes: header, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        // `[v6]:443`, or as WebKit writes it, `fd00::1:443`: the port is after the last colon.
        guard let colon = target.lastIndex(of: ":") else { return nil }
        var host = String(target[..<colon])
        let portText = target[target.index(after: colon)...]
        guard !portText.isEmpty, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
              let port = UInt16(portText), port > 0 else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0 != "/" && $0 != "@" }) else { return nil }
        return ConnectRequest(host: host, port: port)
    }
}

/// `browse_url` from the arguments to the text: checks, the proxy, the app's loader, the answer.
struct BuiltInBrowser: Sendable {
    static let maxCharacters = 1_000_000
    static let maxLinks = 200
    static let loadTimeout: TimeInterval = 25
    static let settleTimeout: TimeInterval = 6

    private let loader: BuiltInPageLoader
    private let floor: MCPOAuthLocality
    private let proxyFloor: MCPOAuthLocality
    private let alsoBlocking: [String]

    /// What the app uses: public addresses only, for the page and for all it loads.
    init(loader: BuiltInPageLoader) {
        self.init(loader: loader, floor: .remote)
    }

    /// Tests only, against a mock on loopback. A `proxyFloor` above `floor` lets the page load from
    /// loopback while everything it reaches through the proxy is held to the app's rule.
    init(loader: BuiltInPageLoader, floor: MCPOAuthLocality, proxyFloor: MCPOAuthLocality? = nil, alsoBlocking: [String] = []) {
        self.loader = loader
        self.floor = floor
        self.proxyFloor = proxyFloor ?? floor
        self.alsoBlocking = alsoBlocking
    }

    /// `budget` is the tool result's limit in characters, so links asked for are not cut off behind
    /// a long text.
    /// `otherSites` is the user's Settings switch: off, the page may reach only its own site.
    func browse(_ arguments: [String: JSONValue], budget: Int? = nil, otherSites: Bool = false) async -> BuiltInAnswer {
        guard let text = arguments["url"]?.stringValue else { return .error("`url` must be a string.") }
        var wantsLinks = false
        if let value = arguments["links"], !value.isNull {
            guard let flag = value.boolValue else { return .error("`links` must be true or false.") }
            wantsLinks = flag
        }
        guard let url = BuiltInFetcher.parse(text), let host = url.host else {
            return .error("Only http and https addresses with a plain host and no user name or password can be opened.")
        }
        do {
            try await BuiltInFetcher.checkHost(host, floor: floor, verb: "opened")
            try Task.checkCancellation()
        } catch let refusal as BuiltInRefusal {
            return .error(refusal.message)
        } catch {
            return .cancelled
        }
        // WebKit connects to some IPv6 literals without the proxy, so the rules block them all,
        // the page itself included. Say so here rather than fail later with no reason.
        if host.contains(":") {
            return .error("IPv6 addresses cannot be opened in the private browser. Use the site's name instead.")
        }

        let proxy: BuiltInBrowseProxy
        let port: UInt16
        do {
            proxy = try BuiltInBrowseProxy(floor: proxyFloor, onlySite: otherSites ? nil : BuiltInBrowsePolicy.site(of: url))
            port = try await proxy.start()
        } catch {
            return Task.isCancelled ? .cancelled : .error("The private browser could not start.")
        }
        defer { proxy.stop() }

        let request = BuiltInBrowseRequest(
            url: url, proxyPort: port,
            contentRules: BuiltInBrowsePolicy.contentRules(blockingLoopback: floor > .loopback, alsoBlocking: alsoBlocking),
            wantsLinks: wantsLinks, maxCharacters: Self.maxCharacters, maxLinks: Self.maxLinks,
            loadTimeout: Self.loadTimeout, settleTimeout: Self.settleTimeout)
        let outcome = await loader.load(request)
        proxy.stop()
        if Task.isCancelled { return .cancelled }

        switch outcome {
        case .page(let page):
            let outcomes = proxy.hostOutcomes
            let blocked = outcomes.filter { $0.outcome == .refused }.map(\.host)
            let others = OtherSites(sites: proxy.otherSitesBlocked, hosts: outcomes.filter { $0.outcome == .otherSite }.map(\.host))
            return .text(Self.render(page, wantsLinks: wantsLinks, refusedHosts: blocked, otherSites: others,
                                     hitByteLimit: proxy.hitByteLimit, budget: budget))
        case .left(let target):
            return .text(Self.leftText(target))
        case .notAPage(let type):
            return .error("Not a web page: \(type.isEmpty ? "no content type" : type). Nothing was downloaded or kept.")
        case .httpError(let status):
            return .error("The server answered HTTP \(status).")
        case .cancelled:
            return .cancelled
        case .failed(let failure):
            return .error(Self.failureText(failure, host: host, proxy: proxy.outcome(for: host)))
        }
    }

    static func failureText(_ failure: BuiltInBrowseFailure, host: String, proxy: BuiltInBrowseProxy.HostOutcome?) -> String {
        // What the proxy saw comes first: the page's own host is checked again there, and a name
        // that changed its answer since the first check is refused, not reported as a failure.
        switch proxy {
        case .refused?: return BuiltInFetcher.refused(host, verb: "opened").message
        case .notFound?: return "\(host) could not be found."
        case .unreachable?: return "The connection to \(host) failed."
        // The page's own host is its own site.
        case .otherSite?, nil: break
        }
        switch failure {
        case .notFound: return "\(host) could not be found."
        case .timedOut: return "\(host) did not answer in time."
        case .insecure: return "The secure connection to \(host) failed."
        case .connection: return "The connection to \(host) failed."
        case .crashed: return "The page stopped the browser that was showing it."
        case .other: return "The page could not be loaded."
        }
    }

    static func leftText(_ target: URL) -> String {
        "The page went to \(target.absoluteString). Parley did not follow it, because that is another address. "
            + "To read it, call browse_url with that address: the user is asked again."
    }

    /// Notes first, as `fetch_url` puts them, then the text, then the links if asked for. With a
    /// `budget` and links asked for, the text is shortened so the links still fit; the links take
    /// at most half of it.
    /// Other sites the page was kept from because the switch is off: how many (host and port),
    /// and the first hosts by name.
    struct OtherSites: Equatable {
        var sites = 0
        var hosts: [String] = []
    }

    static func render(_ page: BuiltInBrowsePage, wantsLinks: Bool, refusedHosts: [String], otherSites: OtherSites = OtherSites(),
                       hitByteLimit: Bool, budget: Int? = nil) -> String {
        var out = "URL: \(page.finalURL)\n"
        let title = oneLine(page.title)
        if !title.isEmpty { out += "Title: \(title)\n" }
        if !page.finishedLoading {
            out += "Note: the page was still loading after \(Int(loadTimeout)) s. This is what it showed by then.\n"
        }
        if hitByteLimit {
            out += "Note: the page loaded more than \(BuiltInBrowseProxy.maxBytes / 1024 / 1024) MiB and was stopped there.\n"
        }
        if !refusedHosts.isEmpty {
            out += "Note: Parley blocked what the page tried to load from this computer, the local network or a VPN: "
                + refusedHosts.joined(separator: ", ") + ".\n"
        }
        if otherSites.sites > 0 {
            let count = otherSites.sites == 1 ? "1 other site" : "\(otherSites.sites) other sites"
            var names = otherSites.hosts.joined(separator: ", ")
            if otherSites.sites > otherSites.hosts.count, !otherSites.hosts.isEmpty {
                names += " and more"
            }
            out += "Note: Parley blocked everything the page tried to load from \(count) (\(names)), "
                + "because only the address the user approved may be loaded. If the text below is missing or incomplete, "
                + "that may be why: the user can allow other sites for Browse Web Page in Settings > Built-in Tools.\n"
        }
        if page.textWasCut {
            out += "Note: the page's text is longer than \(maxCharacters) characters. Only the start was read.\n"
        }
        var text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wantsLinks else { return out + "\n" + (text.isEmpty ? "(The page shows no text.)" : text) }

        var lines = page.links.map { link -> String in
            let label = oneLine(link.text)
            return "\n- " + (label.isEmpty ? link.url : "\(label): \(link.url)")
        }
        var links = "\n\nLinks:" + (lines.isEmpty ? " none" : lines.joined())
        if let budget {
            let linkRoom = max(0, budget / 2)
            if links.count > linkRoom {
                var kept: [String] = []
                var used = "\n\nLinks:".count + 40
                for line in lines where used + line.count <= linkRoom {
                    kept.append(line)
                    used += line.count
                }
                let dropped = lines.count - kept.count
                lines = kept
                links = "\n\nLinks:" + lines.joined() + "\n- … and \(dropped) more, left out to fit."
            }
            let shortenedNote = "Note: the text was shortened to leave room for the links.\n"
            let room = budget - out.count - shortenedNote.count - links.count - 1
            if text.count > room {
                text = String(text.prefix(max(0, room)))
                out += shortenedNote
            }
        }
        return out + "\n" + (text.isEmpty ? "(The page shows no text.)" : text) + links
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
