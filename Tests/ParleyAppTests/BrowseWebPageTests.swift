import Darwin
import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Browse Web Page with real WebKit, against a page server on 127.0.0.1 in this process. Nothing here
// resolves a name or leaves this Mac:
// - the page itself is on loopback, which WebKit reaches without the proxy, so these tests lower the
//   page floor to `.loopback` and keep the proxy at the app's `.remote`;
// - every other address a page names is a literal that the proxy or a content rule refuses before
//   any connection, or `localhost` on the same server, which a test rule blocks;
// - the content rules that block loopback in the app are checked in `BuiltInBrowseTests`, by pattern.

/// A small HTTP server: one request per connection, routes are full responses.
private final class PageServer: @unchecked Sendable {
    struct Request {
        var path: String
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var routes: [String: Data?] = [:]
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound, listen(fd, 64) == 0 else { throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    var origin: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.withLock { recorded } }
    var paths: [String] { requests.map(\.path) }

    func page(_ path: String, _ html: String, headers: [String] = []) {
        route(path, type: "text/html; charset=utf-8", headers: headers, body: html)
    }

    func route(_ path: String, status: String = "200 OK", type: String? = "text/plain", headers: [String] = [], body: String = "") {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        for header in headers { head += header + "\r\n" }
        lock.withLock { routes[path] = Data((head + "\r\n" + body).utf8) }
    }

    /// Takes the request and never answers.
    func hang(_ path: String) { lock.withLock { routes[path] = .some(nil) } }

    private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { close(client); return }
            data.append(buffer, count: count)
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = (lines.first ?? "").split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.withLock { recorded.append(Request(path: path, headers: headers)) }
        switch lock.withLock({ routes[path] }) {
        case .some(.some(let reply)):
            reply.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = write(client, raw.baseAddress! + sent, raw.count - sent)
                    guard count > 0 else { break }
                    sent += count
                }
            }
        case .some(.none):
            _ = read(client, &buffer, buffer.count)
        case .none:
            let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
        }
        close(client)
    }
}

private func text(_ answer: BuiltInAnswer) -> String {
    if case .text(let text) = answer { return text }
    Issue.record("expected text, got \(answer)")
    return ""
}

private func error(_ answer: BuiltInAnswer) -> String {
    if case .error(let text) = answer { return text }
    Issue.record("expected an error, got \(answer)")
    return ""
}

@MainActor
@Suite(.serialized) struct BrowseWebPageTests {
    let loader = WebPageLoader()
    fileprivate let web: PageServer

    init() throws {
        web = try PageServer()
    }

    /// The page on loopback, everything through the proxy held to the app's floor.
    fileprivate func browser(alsoBlocking: [String] = []) -> BuiltInBrowser {
        BuiltInBrowser(loader: loader, floor: .loopback, proxyFloor: .remote, alsoBlocking: alsoBlocking)
    }

    private func browse(_ path: String, links: Bool = false, alsoBlocking: [String] = [], otherSites: Bool = false) async -> BuiltInAnswer {
        var arguments: [String: JSONValue] = ["url": .string(web.origin + path)]
        if links { arguments["links"] = .bool(true) }
        return await browser(alsoBlocking: alsoBlocking).browse(arguments, otherSites: otherSites)
    }

    /// The visit has ended and its web view has been freed, not only dropped from the list.
    private func waitUntilClosed() async {
        for _ in 0..<100 where loader.openPages > 0 || loader.lastWebView != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(loader.lastWebView == nil, "the web view is freed")
    }

    @Test func readsTextThatAScriptWrites() async throws {
        web.page("/", """
            <html><head><title>Rendered  Page</title></head><body>
            <div id="app">Loading…</div>
            <img src="/pixel.png"><video src="/clip.mp4"></video>
            <script>setTimeout(function () { document.getElementById("app").textContent = "Hello from a script"; }, 300);</script>
            </body></html>
            """)
        let page = text(await browse("/"))
        #expect(page.hasPrefix("URL: \(web.origin)/\nTitle: Rendered Page\n\n"))
        #expect(page.contains("Hello from a script"))
        #expect(!page.contains("Loading"))
        #expect(!page.contains("Links:"))
        #expect(!web.paths.contains("/pixel.png"), "images are blocked")
        #expect(!web.paths.contains("/clip.mp4"), "media is blocked")
        #expect(loader.openPages == 0)
        await waitUntilClosed()
    }

    @Test func listsLinksWhenAsked() async throws {
        web.page("/", """
            <html><body><p>Index</p><a href="/a">First   link</a> <a href="/a">Again</a>
            <a href="mailto:x@example.org">Mail</a><a href="https://203.0.113.5/b"><span>Second</span></a></body></html>
            """)
        let page = text(await browse("/", links: true))
        #expect(page.hasSuffix("\n\nLinks:\n- First link: \(web.origin)/a\n- Second: https://203.0.113.5/b"))
        #expect(web.paths == ["/"])
    }

    @Test func followsARedirectOnTheSameOrigin() async throws {
        web.route("/old", status: "302 Found", headers: ["Location: /new"])
        web.page("/new", "<html><body>The new page</body></html>")
        let page = text(await browse("/old"))
        #expect(page.hasPrefix("URL: \(web.origin)/new\n"))
        #expect(page.contains("The new page"))
    }

    @Test func stopsAtARedirectToAnotherOrigin() async throws {
        web.route("/away", status: "302 Found", headers: ["Location: http://localhost:\(web.port)/there#frag"])
        web.page("/there", "<html><body>Should not load</body></html>")
        let answer = text(await browse("/away"))
        #expect(answer == "The page went to http://localhost:\(web.port)/there. Parley did not follow it, because that is another address. "
            + "To read it, call browse_url with that address: the user is asked again.")
        #expect(!web.paths.contains("/there"))
        #expect(loader.openPages == 0)
        await waitUntilClosed()
    }

    @Test func stopsAScriptThatGoesToAnotherOrigin() async throws {
        web.page("/", "<html><body>Here<script>setTimeout(() => { location.href = 'http://localhost:\(web.port)/there'; }, 50);</script></body></html>")
        let answer = text(await browse("/"))
        #expect(answer.hasPrefix("The page went to http://localhost:\(web.port)/there."))
        #expect(!web.paths.contains("/there"))
    }

    @Test func aPageOutside2xxIsAnError() async throws {
        web.route("/gone", status: "404 Not Found", type: "text/html", body: "<html><body>Not here</body></html>")
        #expect(error(await browse("/gone")) == "The server answered HTTP 404.")
        #expect(loader.openPages == 0)
    }

    @Test func waitsForAStubThatMovesOnToItsRealPage() async throws {
        web.page("/stub", "<html><head><meta http-equiv=\"refresh\" content=\"0;url=/real\"></head><body>Redirecting…</body></html>")
        web.page("/js", "<html><body>Loading…<script>setTimeout(() => location.replace('/real'), 200);</script></body></html>")
        web.page("/real", "<html><body><p id=o>first</p><script>setTimeout(() => { document.getElementById('o').textContent = 'The real page'; }, 300);</script></body></html>")
        for path in ["/stub", "/js"] {
            let page = text(await browse(path))
            #expect(page.hasPrefix("URL: \(web.origin)/real\n"), "\(path)")
            #expect(page.contains("The real page"), "\(path)")
        }
    }

    @Test func linksFitBesideALongText() async throws {
        web.page("/", "<html><body><a href=\"/next\">Next</a><p id=t></p><script>document.getElementById('t').textContent = 'word '.repeat(5000);</script></body></html>")
        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["browse_url"]) }, browser: browser())
        let result = await runner.call(BuiltInTools.Tool.browseURL.definition, arguments: ["url": .string(web.origin + "/"), "links": .bool(true)],
                                       timeout: 60, maxCharacters: 2000)
        #expect(result.callStatus == .completed)
        #expect(result.originalCharacters == nil)
        #expect(result.text.hasSuffix("\n\nLinks:\n- Next: \(web.origin)/next"))
    }

    @Test func opensNoWindows() async throws {
        web.page("/", """
            <html><body>Main<a id="l" href="/popup2" target="_blank">x</a>
            <script>window.open("/popup1"); document.getElementById("l").click();</script></body></html>
            """)
        web.page("/popup1", "<html><body>Popup</body></html>")
        web.page("/popup2", "<html><body>Popup</body></html>")
        let page = text(await browse("/"))
        #expect(page.contains("Main"))
        #expect(!web.paths.contains("/popup1") && !web.paths.contains("/popup2"))
    }

    @Test func downloadsNothing() async throws {
        web.route("/file.bin", type: "application/octet-stream", body: String(repeating: "x", count: 4096))
        #expect(error(await browse("/file.bin")) == "Not a web page: application/octet-stream. Nothing was downloaded or kept.")
        web.page("/", "<html><body>Here<iframe src=\"/file.bin\"></iframe><a id=d href=\"/file.bin\" download>d</a>"
            + "<script>document.getElementById('d').click()</script></body></html>")
        #expect(text(await browse("/")).contains("Here"))
        #expect(loader.openPages == 0)
    }

    /// The default: other sites are blocked at the proxy, before any lookup, and the model is told
    /// how many requests that was and where the switch is. 203.0.113.9 is a documentation address:
    /// it is refused here, never reached.
    @Test func otherSitesAreBlockedByDefaultAndCounted() async throws {
        web.page("/", """
            <html><body><p id="out">waiting</p><script>
            Promise.all([fetch("https://203.0.113.9/lib.js"), fetch("https://203.0.113.9/data")].map(p => p.then(() => "reached", () => "blocked")))
              .then(r => { document.getElementById("out").textContent = "other " + r.join(" "); });
            </script></body></html>
            """)
        let page = text(await browse("/"))
        #expect(page.contains("other blocked blocked"))
        // Two requests, one site; WebKit retried each refused CONNECT, which is why sites are counted.
        #expect(page.contains("Note: Parley blocked everything the page tried to load from 1 other site (203.0.113.9), "))
        #expect(page.contains("in Settings > Built-in Tools."))
    }

    /// With the switch on, other sites go through the address check; a LAN one is still refused.
    @Test func refusesTheLocalNetworkThroughTheProxy() async throws {
        web.page("/", """
            <html><body><p id="out">waiting</p><script>
            fetch("http://10.255.255.1:8080/x").then(() => "reached", () => "refused")
              .then(r => { document.getElementById("out").textContent = "LAN " + r; });
            </script></body></html>
            """)
        let page = text(await browse("/", otherSites: true))
        #expect(page.contains("LAN refused"))
        #expect(page.contains("Note: Parley blocked what the page tried to load from this computer, the local network or a VPN: 10.255.255.1."))
    }

    @Test func contentRulesBlockWhatBypassesTheProxy() async throws {
        web.route("/secret", body: "secret")
        web.page("/", """
            <html><body><p id="out">waiting</p><script>
            fetch("http://localhost:\(web.port)/secret").then(r => r.text()).then(t => "got " + t, () => "blocked")
              .then(r => { document.getElementById("out").textContent = r; });
            </script></body></html>
            """)
        let page = text(await browse("/", alsoBlocking: ["localhost"]))
        #expect(page.contains("blocked"))
        #expect(!web.paths.contains("/secret"))
    }

    @Test func keepsNothingBetweenCalls() async throws {
        web.page("/", "<html><body>Cookie<script>localStorage.setItem('k', 'v'); document.cookie = 'b=2';</script></body></html>",
                 headers: ["Set-Cookie: a=1; Max-Age=3600"])
        web.page("/second", "<html><body><p id=o></p><script>document.getElementById('o').textContent = 'stored:' + localStorage.getItem('k');</script></body></html>")
        _ = text(await browse("/"))
        let page = text(await browse("/second"))
        #expect(page.contains("stored:null"))
        let second = try #require(web.requests.last { $0.path == "/second" })
        #expect(second.headers["cookie"] == nil)
    }

    @Test func hasNoWebRTC() async throws {
        // Also from a new frame's first empty document, where no user script runs.
        web.page("/", """
            <html><body><p id=o></p><script>
            const f = document.body.appendChild(document.createElement('iframe'));
            document.getElementById('o').textContent = 'rtc:' + typeof RTCPeerConnection + ' frame:' + typeof f.contentWindow.RTCPeerConnection;
            </script></body></html>
            """)
        #expect(text(await browse("/")).contains("rtc:undefined frame:undefined"))
    }

    @Test func cutsALongPageAndTheToolResultSaysSo() async throws {
        web.page("/", "<html><body><script>document.body.textContent = 'a'.repeat(\(BuiltInBrowser.maxCharacters + 5000));</script></body></html>")
        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["browse_url"]) }, browser: browser())
        let result = await runner.call(BuiltInTools.Tool.browseURL.definition, arguments: ["url": .string(web.origin + "/")],
                                       timeout: 60, maxCharacters: 400)
        #expect(result.callStatus == .completed)
        #expect(result.text.contains("Note: the page's text is longer than \(BuiltInBrowser.maxCharacters) characters. Only the start was read."))
        let total = try #require(result.originalCharacters)
        #expect(total > BuiltInBrowser.maxCharacters)
        #expect(result.text.hasSuffix("\n\n[Truncated by Parley: showing the first 400 of \(total) characters.]"))
    }

    @Test func cancellingClosesThePage() async throws {
        web.hang("/slow")
        let task = Task { await browse("/slow") }
        for _ in 0..<100 where !web.paths.contains("/slow") { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(loader.openPages == 1)
        let started = Date()
        task.cancel()
        let answer = await task.value
        #expect(answer == .cancelled)
        #expect(Date().timeIntervalSince(started) < 3)
        await waitUntilClosed()
        #expect(loader.openPages == 0)
    }

    @Test func theCallTimeoutClosesThePage() async throws {
        web.hang("/slow")
        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["browse_url"]) }, browser: browser())
        let result = await runner.call(BuiltInTools.Tool.browseURL.definition, arguments: ["url": .string(web.origin + "/slow")],
                                       timeout: 1.5, maxCharacters: 1000)
        #expect(result.callStatus == .timedOut)
        await waitUntilClosed()
        #expect(loader.openPages == 0)
    }

    @Test func quitCancelsEveryPage() async throws {
        web.hang("/slow")
        let task = Task { await browse("/slow") }
        for _ in 0..<100 where loader.openPages == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        loader.cancelAll()
        #expect(loader.openPages == 0)
        await waitUntilClosed()
        let answer = await task.value
        #expect(answer == .cancelled)
    }

    /// The app's floor: the loopback page is refused before anything starts.
    @Test func theAppRefusesThisMac() async throws {
        web.page("/", "<html><body>here</body></html>")
        let answer = await BuiltInBrowser(loader: loader).browse(["url": .string(web.origin + "/")])
        #expect(error(answer) == "127.0.0.1 was refused: only public internet addresses can be opened, not this computer, the local network or a VPN.")
        #expect(web.paths.isEmpty)
        #expect(loader.openPages == 0)
    }
}
