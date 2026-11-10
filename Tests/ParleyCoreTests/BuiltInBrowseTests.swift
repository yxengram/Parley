import Darwin
import Foundation
import Testing
@testable import ParleyCore

// browse_url's core: the address and navigation rules, the content rules, the proxy every page
// request goes through, and what the model is told. The WebKit side is tested in the app
// (BrowseWebPageTests). Nothing here resolves a name or leaves this Mac: the proxy tests use
// LoopbackWeb, and every refused host is refused by its text, before any lookup or connection.

// MARK: Helpers

/// What the app's loader was asked, and an answer chosen by the test.
private final class FakeLoader: BuiltInPageLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BuiltInBrowseRequest] = []
    private var sawCancel = false
    private let outcome: BuiltInBrowseOutcome?

    /// Nil: wait until cancelled.
    init(_ outcome: BuiltInBrowseOutcome?) { self.outcome = outcome }

    var asked: [BuiltInBrowseRequest] { lock.withLock { requests } }
    var wasCancelled: Bool { lock.withLock { sawCancel } }

    func load(_ request: BuiltInBrowseRequest) async -> BuiltInBrowseOutcome {
        lock.withLock { requests.append(request) }
        if let outcome { return outcome }
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        lock.withLock { sawCancel = true }
        return .cancelled
    }
}

/// A blocking TCP client on 127.0.0.1, for talking to the proxy as WebKit does.
private final class RawClient {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // No close here: a class whose init throws still runs deinit, and closing twice could close
        // a descriptor another test has been given since.
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    deinit { close(fd) }

    func send(_ text: String) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    /// Up to the blank line after the headers.
    func readHead() -> String {
        var data = Data()
        var byte: UInt8 = 0
        while data.range(of: Data("\r\n\r\n".utf8)) == nil, read(fd, &byte, 1) == 1 { data.append(byte) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Until the other side closes, or `limit` bytes.
    func readAll(limit: Int = 1 << 24) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < limit {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func onThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached { try work() }.value
}

private func connectStatus(_ proxy: BuiltInBrowseProxy, port: UInt16, target: String) async throws -> String {
    try await onThread {
        let client = try RawClient(port: port)
        client.send("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        return client.readHead().components(separatedBy: "\r\n").first ?? ""
    }
}

// MARK: Pure rules

@Suite struct BuiltInBrowsePolicyTests {
    private let approved = URL(string: "https://example.org/start")!

    @Test func theMainFrameStaysOnTheApprovedOrigin() {
        func decide(_ text: String) -> BuiltInBrowsePolicy.Navigation {
            BuiltInBrowsePolicy.navigation(to: URL(string: text), isMainFrame: true, approved: approved)
        }
        #expect(decide("https://example.org/other?q=1") == .allow)
        #expect(decide("https://EXAMPLE.org:443/") == .allow)
        #expect(decide("https://example.org/#top") == .allow)
        #expect(decide("http://example.org/") == .leave(URL(string: "http://example.org/")!))
        #expect(decide("https://example.org:8443/") == .leave(URL(string: "https://example.org:8443/")!))
        #expect(decide("https://www.example.org/a#frag") == .leave(URL(string: "https://www.example.org/a")!))
        #expect(decide("https://user@example.org/") == .leave(URL(string: "https://user@example.org/")!))
        for other in ["file:///etc/passwd", "mailto:a@example.org", "about:blank", "data:text/html,hi", "javascript:alert(1)", "x-app://open"] {
            #expect(decide(other) == .cancel, "\(other)")
        }
        #expect(BuiltInBrowsePolicy.navigation(to: nil, isMainFrame: true, approved: approved) == .cancel)
    }

    @Test func framesMayLoadTheWebButNoOtherScheme() {
        func decide(_ text: String) -> BuiltInBrowsePolicy.Navigation {
            BuiltInBrowsePolicy.navigation(to: URL(string: text), isMainFrame: false, approved: approved)
        }
        for allowed in ["https://ads.example.net/frame", "http://cdn.example.com/", "about:blank", "about:srcdoc", "data:text/html,x", "blob:https://example.org/1"] {
            #expect(decide(allowed) == .allow, "\(allowed)")
        }
        for refused in ["file:///etc/passwd", "ftp://example.org/", "mailto:a@example.org", "x-app://open"] {
            #expect(decide(refused) == .cancel, "\(refused)")
        }
    }

    @Test func onlyPagesWithTextAreShown() {
        #expect(BuiltInBrowsePolicy.showsAsPage(mimeType: "text/html", canShow: true))
        #expect(BuiltInBrowsePolicy.showsAsPage(mimeType: "text/plain", canShow: true))
        #expect(BuiltInBrowsePolicy.showsAsPage(mimeType: nil, canShow: true))
        #expect(!BuiltInBrowsePolicy.showsAsPage(mimeType: "application/octet-stream", canShow: false))
        #expect(!BuiltInBrowsePolicy.showsAsPage(mimeType: "application/pdf", canShow: true))
        #expect(!BuiltInBrowsePolicy.showsAsPage(mimeType: "IMAGE/PNG", canShow: true))
        #expect(!BuiltInBrowsePolicy.showsAsPage(mimeType: "video/mp4", canShow: true))
    }

    @Test func theTextHasSettledWhenThreeSamplesAgree() {
        #expect(!BuiltInBrowsePolicy.isSettled([]))
        #expect(!BuiltInBrowsePolicy.isSettled([10, 10]))
        #expect(BuiltInBrowsePolicy.isSettled([10, 10, 10]))
        #expect(!BuiltInBrowsePolicy.isSettled([10, 10, 12]))
        #expect(BuiltInBrowsePolicy.isSettled([0, 5, 12, 12, 12]))
        #expect(!BuiltInBrowsePolicy.isSettled([12, 12, 12, 13]))
    }

    @Test func connectRequestsAreParsedStrictly() {
        func parse(_ text: String) -> BuiltInBrowsePolicy.ConnectRequest? {
            BuiltInBrowsePolicy.parseConnect(Array(text.utf8))
        }
        #expect(parse("CONNECT example.org:443 HTTP/1.1\r\nHost: example.org:443") == .init(host: "example.org", port: 443))
        #expect(parse("CONNECT 93.184.216.34:80 HTTP/1.1") == .init(host: "93.184.216.34", port: 80))
        // WebKit writes an IPv6 host without brackets.
        #expect(parse("CONNECT fd00::1:443 HTTP/1.1") == .init(host: "fd00::1", port: 443))
        #expect(parse("CONNECT [2001:db8::1]:8080 HTTP/1.1") == .init(host: "2001:db8::1", port: 8080))
        for bad in ["GET http://example.org/ HTTP/1.1", "CONNECT example.org HTTP/1.1", "CONNECT example.org:0 HTTP/1.1",
                    "CONNECT example.org:70000 HTTP/1.1", "CONNECT example.org:+80 HTTP/1.1", "CONNECT :443 HTTP/1.1",
                    "CONNECT a@example.org:443 HTTP/1.1", "CONNECT example.org:443 SPDY/3", "CONNECT  example.org:443 HTTP/1.1",
                    "connect example.org:443 HTTP/1.1", "CONNECT ex\u{0430}mple.org:443 HTTP/1.1", ""] {
            #expect(parse(bad) == nil, "\(bad)")
        }
    }

    private func filters(_ json: String) throws -> [(filter: String, types: [String]?, loadType: [String]?)] {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return rules.map {
            let trigger = $0["trigger"] as? [String: Any] ?? [:]
            #expect(($0["action"] as? [String: Any])?["type"] as? String == "block")
            return (trigger["url-filter"] as? String ?? "", trigger["resource-type"] as? [String], trigger["load-type"] as? [String])
        }
    }

    @Test func imagesMediaFontsPopupsPingsAndOtherSitesFramesAreBlocked() throws {
        let rules = try filters(BuiltInBrowsePolicy.contentRules(blockingLoopback: false))
        #expect(rules.count == 2)
        #expect(Set(rules[0].types ?? []) == ["image", "media", "font", "svg-document", "popup", "ping"])
        #expect(rules[1].types == ["document"] && rules[1].loadType == ["third-party"])
    }

    /// WebKit connects to these without the proxy, so a rule must catch each. The patterns use only
    /// what WebKit's rule syntax has, so ICU reads them the same way.
    @Test func everythingOnThisMacIsBlockedByARule() throws {
        let rules = try filters(BuiltInBrowsePolicy.contentRules(blockingLoopback: true)).filter { $0.types == nil }
        let patterns = try rules.map { try NSRegularExpression(pattern: $0.filter, options: [.caseInsensitive]) }
        func blocked(_ url: String) -> Bool {
            patterns.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        for url in ["http://localhost/", "http://localhost:8080/x", "https://localhost./", "ws://localhost:9/socket", "http://a:b@localhost/",
                    "http://api.localhost/", "http://127.0.0.1/", "http://127.1.2.3:5000/", "http://0.0.0.0/", "http://[::1]:8080/",
                    "http://[::ffff:7f00:1]/", "wss://[fe80::1]/", "HTTP://LOCALHOST/", "http://user@127.0.0.1/"] {
            #expect(blocked(url), "\(url)")
        }
        for url in ["https://example.org/", "https://localhost.example.org/", "https://example.org/localhost/", "https://notlocalhost/",
                    "https://example.org/?u=http://127.0.0.1/", "https://127example.org/", "https://a.b/0.0.0.0/",
                    "https://0.gravatar.com/avatar", "http://127.example.org/"] {
            #expect(!blocked(url), "\(url)")
        }
        #expect(try filters(BuiltInBrowsePolicy.contentRules(blockingLoopback: false)).allSatisfy { $0.types != nil })
    }

    @Test func aTestCanBlockOneMoreHost() throws {
        let rules = try filters(BuiltInBrowsePolicy.contentRules(blockingLoopback: false, alsoBlocking: ["local.test"]))
        #expect(rules.last?.filter == "^[a-z][a-z0-9+.-]*://([^/]*@)?local\\.test\\.?[:/]")
    }
}

// MARK: What the model reads

@Suite struct BuiltInBrowseTextTests {
    @Test func aPageReadsLikeAFetchedOne() {
        let page = BuiltInBrowsePage(finalURL: "https://example.org/a", title: " The\n Title ", text: "\n  Body text\n\nMore  \n",
                                     links: [BuiltInBrowseLink(text: "x", url: "https://example.org/x")])
        #expect(BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [], hitByteLimit: false)
            == "URL: https://example.org/a\nTitle: The Title\n\nBody text\n\nMore")
    }

    @Test func notesComeBeforeTheText() {
        let page = BuiltInBrowsePage(finalURL: "https://example.org/", title: "", text: "", textWasCut: true, finishedLoading: false)
        let text = BuiltInBrowser.render(page, wantsLinks: true, refusedHosts: ["10.0.0.1", "printer.local"], hitByteLimit: true)
        #expect(text == """
            URL: https://example.org/
            Note: the page was still loading after 25 s. This is what it showed by then.
            Note: the page loaded more than 64 MiB and was stopped there.
            Note: Parley blocked what the page tried to load from this computer, the local network or a VPN: 10.0.0.1, printer.local.
            Note: the page's text is longer than 1000000 characters. Only the start was read.

            (The page shows no text.)

            Links: none
            """)
    }

    @Test func linksAreOneLineEach() {
        let page = BuiltInBrowsePage(finalURL: "https://example.org/", title: "T", text: "t", links: [
            BuiltInBrowseLink(text: "Two\nlines", url: "https://example.org/1"),
            BuiltInBrowseLink(text: "  ", url: "https://example.org/2"),
        ])
        #expect(BuiltInBrowser.render(page, wantsLinks: true, refusedHosts: [], hitByteLimit: false).hasSuffix(
            "\n\nLinks:\n- Two lines: https://example.org/1\n- https://example.org/2"))
    }

    @Test func linksAskedForStillFitWhenTheTextIsLong() {
        let page = BuiltInBrowsePage(finalURL: "https://example.org/", title: "T", text: String(repeating: "a", count: 5000),
                                     links: [BuiltInBrowseLink(text: "One", url: "https://example.org/1")])
        let text = BuiltInBrowser.render(page, wantsLinks: true, refusedHosts: [], hitByteLimit: false, budget: 1000)
        #expect(text.count <= 1000)
        #expect(text.contains("Note: the text was shortened to leave room for the links.\n"))
        #expect(text.hasSuffix("aaa\n\nLinks:\n- One: https://example.org/1"))
        // Without links, the text is left for the tool result's own cut.
        #expect(BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [], hitByteLimit: false, budget: 1000).count > 5000)
    }

    @Test func tooManyLinksTakeHalfTheBudgetAtMost() {
        let links = (1...100).map { BuiltInBrowseLink(text: "Link \($0)", url: "https://example.org/\($0)") }
        let page = BuiltInBrowsePage(finalURL: "https://example.org/", title: "", text: "Body", links: links)
        let text = BuiltInBrowser.render(page, wantsLinks: true, refusedHosts: [], hitByteLimit: false, budget: 1000)
        #expect(text.count <= 1000)
        #expect(text.contains("\nBody\n\nLinks:\n- Link 1: https://example.org/1\n"))
        #expect(text.range(of: #"\n- … and \d+ more, left out to fit\.$"#, options: .regularExpression) != nil)
        #expect(!text.contains("Note: the text was shortened"))
    }

    @Test func blockedRequestsToOtherSitesAreCountedAndExplained() {
        let page = BuiltInBrowsePage(finalURL: "https://example.org/", title: "", text: "Loading")
        let one = BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [],
                                        otherSites: .init(sites: 1, hosts: ["cdn.example.net"]), hitByteLimit: false)
        #expect(one == "URL: https://example.org/\nNote: Parley blocked everything the page tried to load from 1 other site (cdn.example.net), "
            + "because only the address the user approved may be loaded. If the text below is missing or incomplete, that may be why: "
            + "the user can allow other sites for Browse Web Page in Settings > Built-in Tools.\n\nLoading")
        let many = BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [],
                                         otherSites: .init(sites: 3, hosts: ["a.example", "b.example", "c.example"]), hitByteLimit: false)
        #expect(many.contains("Parley blocked everything the page tried to load from 3 other sites (a.example, b.example, c.example), "))
        let more = BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [],
                                         otherSites: .init(sites: 25, hosts: ["a.example"]), hitByteLimit: false)
        #expect(more.contains("from 25 other sites (a.example and more), "))
        #expect(!BuiltInBrowser.render(page, wantsLinks: false, refusedHosts: [], hitByteLimit: false).contains("other sites"))
    }

    @Test func theSiteIsTheHostAndPortAsTheProxySeesThem() throws {
        let https = try #require(BuiltInBrowsePolicy.site(of: URL(string: "https://Example.org/a")!))
        #expect(https.host == "example.org" && https.port == 443)
        let http = try #require(BuiltInBrowsePolicy.site(of: URL(string: "http://example.org:8080/")!))
        #expect(http.host == "example.org" && http.port == 8080)
        #expect(BuiltInBrowsePolicy.isSameSite(host: "EXAMPLE.org.", port: 443, as: ("example.org", 443)))
        #expect(!BuiltInBrowsePolicy.isSameSite(host: "example.org", port: 80, as: ("example.org", 443)))
        #expect(!BuiltInBrowsePolicy.isSameSite(host: "cdn.example.org", port: 443, as: ("example.org", 443)))
        #expect(!BuiltInBrowsePolicy.isSameSite(host: "example.org.evil", port: 443, as: ("example.org", 443)))
    }

    @Test func whatTheProxySawExplainsAFailure() {
        #expect(BuiltInBrowser.failureText(.connection, host: "a.example", proxy: .refused)
            == "a.example was refused: only public internet addresses can be opened, not this computer, the local network or a VPN.")
        #expect(BuiltInBrowser.failureText(.connection, host: "a.example", proxy: .notFound) == "a.example could not be found.")
        #expect(BuiltInBrowser.failureText(.other, host: "a.example", proxy: .unreachable) == "The connection to a.example failed.")
        #expect(BuiltInBrowser.failureText(.timedOut, host: "a.example", proxy: nil) == "a.example did not answer in time.")
        #expect(BuiltInBrowser.failureText(.insecure, host: "a.example", proxy: nil) == "The secure connection to a.example failed.")
        #expect(BuiltInBrowser.failureText(.crashed, host: "a.example", proxy: nil) == "The page stopped the browser that was showing it.")
    }

    @Test func theCardNamesTheHostAndSaysWhetherOtherSitesMayBeReached() {
        let arguments: [String: JSONValue] = ["url": .string("https://example.org:8443/a?b")]
        #expect(BuiltInTools.approvalDetail(toolName: "browse_url", arguments: arguments, folderPath: nil)
            == "Built-in tool, opens example.org in a private browser, loading only from that site")
        #expect(BuiltInTools.approvalDetail(toolName: "browse_url", arguments: arguments, folderPath: nil, browseOtherSites: true)
            == "Built-in tool, opens example.org in a private browser; its scripts may contact other public sites")
        #expect(BuiltInTools.approvalDetail(toolName: "fetch_url", arguments: arguments, folderPath: nil, browseOtherSites: true)
            == "Built-in tool, contacts example.org")
        #expect(BuiltInTools.approvalDetail(toolName: "browse_url", arguments: ["url": .string("ftp://example.org/")], folderPath: nil)
            == "Built-in tool")
    }

    @Test func theDefinitionOffersLinksAsAnOption() {
        let schema = BuiltInTools.Tool.browseURL.definition.inputSchema
        #expect(schema["required"] == .array([.string("url")]))
        #expect(schema["properties"]?["links"]?["type"]?.stringValue == "boolean")
        #expect(BuiltInTools.Tool.browseURL.asksEveryTime && BuiltInTools.Tool.browseURL.contactsWebsites)
        #expect(!BuiltInTools.Tool.browseURL.needsFolder)
    }
}

// MARK: From the arguments to the answer, with a fake loader

@Suite struct BuiltInBrowserTests {
    private let page = BuiltInBrowsePage(finalURL: "http://127.0.0.1:1/", title: "Fake", text: "Fake text")

    private func runner(_ browser: BuiltInBrowser?) -> BuiltInToolRunner {
        BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["browse_url"]) }, browser: browser)
    }

    private var tool: MCPTool { BuiltInTools.Tool.browseURL.definition }

    @Test func withoutTheAppTheToolSaysSo() async {
        let result = await runner(nil).call(tool, arguments: ["url": .string("https://example.org/")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .toolError)
        #expect(result.text == "The tool reported an error:\nBrowse Web Page is not available here.")
    }

    @Test func aToolThatIsOffDoesNotRun() async {
        let loader = FakeLoader(.page(page))
        let off = BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["fetch_url"]) }, browser: BuiltInBrowser(loader: loader))
        let result = await off.call(tool, arguments: ["url": .string("https://example.org/")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .notCalled)
        #expect(loader.asked.isEmpty)
    }

    /// Each refused before a lookup, so nothing here reaches a resolver.
    @Test(arguments: [
        ("ftp://example.org/", "Only http and https addresses with a plain host and no user name or password can be opened."),
        ("https://user:pw@example.org/", "Only http and https addresses with a plain host and no user name or password can be opened."),
        ("file:///etc/passwd", "Only http and https addresses with a plain host and no user name or password can be opened."),
        ("http://10.0.0.1/", "10.0.0.1 was refused: only public internet addresses can be opened, not this computer, the local network or a VPN."),
        ("http://localhost:8080/", "localhost was refused: only public internet addresses can be opened, not this computer, the local network or a VPN."),
        ("http://[::1]/", "::1 was refused: only public internet addresses can be opened, not this computer, the local network or a VPN."),
        ("http://printer.local/", "printer.local was refused: only public internet addresses can be opened, not this computer, the local network or a VPN."),
        ("http://router/", "router was refused: only public internet addresses can be opened, not this computer, the local network or a VPN."),
    ])
    func refusedAddressesNeverReachTheApp(url: String, message: String) async {
        let loader = FakeLoader(.page(page))
        let answer = await BuiltInBrowser(loader: loader).browse(["url": .string(url)])
        #expect(answer == .error(message))
        #expect(loader.asked.isEmpty)
    }

    /// A numeric address: nothing is looked up.
    @Test func aPublicIPv6AddressIsRefusedWithAReason() async {
        let loader = FakeLoader(.page(page))
        let answer = await BuiltInBrowser(loader: loader).browse(["url": .string("https://[2606:4700:4700::1111]/")])
        #expect(answer == .error("IPv6 addresses cannot be opened in the private browser. Use the site's name instead."))
        #expect(loader.asked.isEmpty)
    }

    @Test func badArgumentsAreErrors() async {
        let loader = FakeLoader(.page(page))
        let browser = BuiltInBrowser(loader: loader)
        #expect(await browser.browse([:]) == .error("`url` must be a string."))
        #expect(await browser.browse(["url": .int(1)]) == .error("`url` must be a string."))
        #expect(await browser.browse(["url": .string("https://example.org/"), "links": .string("yes")]) == .error("`links` must be true or false."))
        #expect(loader.asked.isEmpty)
    }

    @Test func theAppGetsTheProxyAndTheRules() async throws {
        let loader = FakeLoader(.page(page))
        let answer = await BuiltInBrowser(loader: loader, floor: .loopback).browse(["url": .string("http://127.0.0.1:1/a#frag"), "links": .bool(true)])
        #expect(answer == .text("URL: http://127.0.0.1:1/\nTitle: Fake\n\nFake text\n\nLinks: none"))
        let request = try #require(loader.asked.first)
        #expect(request.url.absoluteString == "http://127.0.0.1:1/a")
        #expect(request.proxyPort != 0)
        #expect(request.wantsLinks)
        #expect(request.maxCharacters == BuiltInBrowser.maxCharacters && request.maxLinks == BuiltInBrowser.maxLinks)
        #expect(request.contentRules == BuiltInBrowsePolicy.contentRules(blockingLoopback: false))
        // The proxy is gone once the call is (its listener closes on its own queue).
        var open = true
        for _ in 0..<100 where open {
            open = (try? RawClient(port: request.proxyPort)) != nil
            if open { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(!open)
    }

    @Test func otherOutcomes() async {
        func answer(_ outcome: BuiltInBrowseOutcome) async -> BuiltInAnswer {
            await BuiltInBrowser(loader: FakeLoader(outcome), floor: .loopback).browse(["url": .string("http://127.0.0.1:1/")])
        }
        #expect(await answer(.left(to: URL(string: "https://other.example/x")!)) == .text(
            "The page went to https://other.example/x. Parley did not follow it, because that is another address. "
                + "To read it, call browse_url with that address: the user is asked again."))
        #expect(await answer(.notAPage(mimeType: "application/zip")) == .error("Not a web page: application/zip. Nothing was downloaded or kept."))
        #expect(await answer(.httpError(404)) == .error("The server answered HTTP 404."))
        #expect(await answer(.failed(.timedOut)) == .error("127.0.0.1 did not answer in time."))
        #expect(await answer(.cancelled) == .cancelled)
    }

    @Test func theCallTimeoutCancelsTheApp() async {
        let loader = FakeLoader(nil)
        let start = Date()
        let result = await runner(BuiltInBrowser(loader: loader, floor: .loopback))
            .call(tool, arguments: ["url": .string("http://127.0.0.1:1/")], timeout: 0.3, maxCharacters: 1000)
        #expect(result.callStatus == .timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
        for _ in 0..<200 where !loader.wasCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(loader.wasCancelled)
    }

    @Test func stopCancelsTheApp() async {
        let loader = FakeLoader(nil)
        let call = Task {
            await runner(BuiltInBrowser(loader: loader, floor: .loopback))
                .call(tool, arguments: ["url": .string("http://127.0.0.1:1/")], timeout: 30, maxCharacters: 1000)
        }
        for _ in 0..<200 where loader.asked.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        call.cancel()
        let result = await call.value
        #expect(result.callStatus == .cancelled)
        for _ in 0..<200 where !loader.wasCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(loader.wasCancelled)
    }

    @Test func aLongPageIsCutAsAnyToolResultIs() async {
        let long = BuiltInBrowsePage(finalURL: "http://127.0.0.1:1/", title: "", text: String(repeating: "word ", count: 500))
        let result = await runner(BuiltInBrowser(loader: FakeLoader(.page(long)), floor: .loopback))
            .call(tool, arguments: ["url": .string("http://127.0.0.1:1/")], timeout: 5, maxCharacters: 100)
        #expect(result.callStatus == .completed)
        let total = "URL: http://127.0.0.1:1/\n\n".count + String(repeating: "word ", count: 500).trimmingCharacters(in: .whitespaces).count
        #expect(result.originalCharacters == total)
        #expect(result.text.hasSuffix("\n\n[Truncated by Parley: showing the first 100 of \(total) characters.]"))
    }
}

// MARK: The proxy

@Suite struct BuiltInBrowseProxyTests {
    @Test func tunnelsToAnAllowedHost() async throws {
        let web = try LoopbackWeb()
        web.route("/", "through the tunnel")
        let proxy = try BuiltInBrowseProxy(floor: .loopback)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let (head, body) = try await onThread { () -> (String, String) in
            let client = try RawClient(port: port)
            client.send("CONNECT 127.0.0.1:\(web.port) HTTP/1.1\r\nHost: 127.0.0.1:\(web.port)\r\n\r\n")
            let head = client.readHead()
            client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            return (head, String(decoding: client.readAll(), as: UTF8.self))
        }
        #expect(head == "HTTP/1.1 200 Connection Established\r\n\r\n")
        #expect(body.hasPrefix("HTTP/1.1 200 OK"))
        #expect(body.hasSuffix("through the tunnel"))
        #expect(proxy.hostOutcomes.isEmpty)
    }

    @Test func refusesThisMacAtTheAppsFloor() async throws {
        let web = try LoopbackWeb()
        web.route("/", "secret")
        let proxy = try BuiltInBrowseProxy(floor: .remote)
        let port = try await proxy.start()
        defer { proxy.stop() }
        #expect(try await connectStatus(proxy, port: port, target: "127.0.0.1:\(web.port)") == "HTTP/1.1 403 Forbidden")
        #expect(web.requests.isEmpty)
        #expect(proxy.outcome(for: "127.0.0.1") == .refused)
    }

    /// Refused by their text: no lookup, no connection.
    @Test func refusesTheLocalNetworkWithoutContactingIt() async throws {
        let proxy = try BuiltInBrowseProxy(floor: .remote)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let targets = ["10.0.0.1:80", "192.168.1.1:443", "172.16.0.1:80", "169.254.169.254:80", "100.64.0.1:80", "[::1]:80",
                       "fd00::1:443", "fe80::1:80", "localhost:80", "api.localhost:80", "printer.local:631", "router:80",
                       "0.0.0.0:80", "2130706433:80", "[::ffff:127.0.0.1]:80"]
        for target in targets {
            #expect(try await connectStatus(proxy, port: port, target: target) == "HTTP/1.1 403 Forbidden", "\(target)")
        }
        #expect(proxy.hostOutcomes.count == targets.count)
        #expect(proxy.hostOutcomes.allSatisfy { $0.outcome == .refused })
        #expect(proxy.outcome(for: "[::1]") == .refused)
    }

    /// The switch off: the approved site only. Another site is refused before any lookup, public or not.
    @Test func withOtherSitesOffOnlyTheApprovedSiteIsReached() async throws {
        let web = try LoopbackWeb()
        web.route("/", "own site")
        let proxy = try BuiltInBrowseProxy(floor: .loopback, onlySite: ("127.0.0.1", UInt16(web.port)))
        let port = try await proxy.start()
        defer { proxy.stop() }
        #expect(try await connectStatus(proxy, port: port, target: "127.0.0.1:\(web.port)") == "HTTP/1.1 200 Connection Established")
        for target in ["127.0.0.1:\(web.port == 65535 ? 1 : web.port + 1)", "cdn.example.net:443", "cdn.example.net:443", "10.0.0.1:80"] {
            #expect(try await connectStatus(proxy, port: port, target: target) == "HTTP/1.1 403 Forbidden", "\(target)")
        }
        // Sites, not attempts: cdn.example.net:443 twice is one; the loopback port is its own site.
        #expect(proxy.otherSitesBlocked == 3)
        #expect(proxy.outcome(for: "cdn.example.net") == .otherSite)
        #expect(proxy.outcome(for: "10.0.0.1") == .otherSite)
        #expect(proxy.hostOutcomes.filter { $0.outcome == .otherSite }.count == 3)
    }

    @Test func onlyConnectIsAccepted() async throws {
        let proxy = try BuiltInBrowseProxy(floor: .loopback)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let answers = try await onThread { () -> [String] in
            var out: [String] = []
            for request in ["GET http://127.0.0.1/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "hello\r\n\r\n",
                            "CONNECT 127.0.0.1 HTTP/1.1\r\n\r\n", "CONNECT 127.0.0.1:80 HTTP/1.1\r\n" + String(repeating: "X: y\r\n", count: 2000)] {
                let client = try RawClient(port: port)
                client.send(request)
                out.append(client.readHead().components(separatedBy: "\r\n").first ?? "")
            }
            return out
        }
        #expect(answers == ["HTTP/1.1 405 Method Not Allowed", "HTTP/1.1 405 Method Not Allowed",
                            "HTTP/1.1 405 Method Not Allowed", "HTTP/1.1 400 Bad Request"])
    }

    @Test func aClosedPortIsReportedAsUnreachable() async throws {
        let proxy = try BuiltInBrowseProxy(floor: .loopback)
        let port = try await proxy.start()
        defer { proxy.stop() }
        // A port nothing listens on: bind one, read its number, close it.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 } }
        let free = UInt16(bigEndian: addr.sin_port)
        close(fd)
        #expect(try await connectStatus(proxy, port: port, target: "127.0.0.1:\(free)") == "HTTP/1.1 502 Bad Gateway")
        #expect(proxy.outcome(for: "127.0.0.1") == .unreachable)
    }

    @Test func stopClosesEveryTunnelAndTheListener() async throws {
        let web = try LoopbackWeb()
        web.hang("/")
        let proxy = try BuiltInBrowseProxy(floor: .loopback)
        let port = try await proxy.start()
        let started = Date()
        let rest = try await onThread { () -> Data in
            let client = try RawClient(port: port)
            client.send("CONNECT 127.0.0.1:\(web.port) HTTP/1.1\r\n\r\n")
            _ = client.readHead()
            client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { proxy.stop() }
            return client.readAll()
        }
        #expect(rest.isEmpty)
        #expect(Date().timeIntervalSince(started) < 3)
        // The listener closes on the proxy's own queue, a moment after `stop`.
        var open = true
        for _ in 0..<100 where open {
            open = (try? RawClient(port: port)) != nil
            if open { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(!open)
        proxy.stop()
    }

    @Test func aPageThatLoadsTooMuchIsStopped() async throws {
        let web = try LoopbackWeb()
        web.route("/", body: Data(repeating: 0x61, count: 2_000_000))
        let proxy = try BuiltInBrowseProxy(floor: .loopback, byteLimit: 100_000)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let received = try await onThread { () -> Int in
            let client = try RawClient(port: port)
            client.send("CONNECT 127.0.0.1:\(web.port) HTTP/1.1\r\n\r\n")
            _ = client.readHead()
            client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            return client.readAll().count
        }
        #expect(received <= 100_000)
        #expect(proxy.hitByteLimit)
    }
}
