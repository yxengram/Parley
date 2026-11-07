import Darwin
import Foundation
import Testing
@testable import ParleyCore

// fetch_url against a listener on loopback, with the floor that only tests can set. Nothing here
// resolves a name or leaves this Mac: the refused hosts are refused before any lookup or connection.

/// One HTTP listener on 127.0.0.1. A route is a full response; an unknown path is a 404.
private final class LoopbackWeb: @unchecked Sendable {
    struct Request {
        var line: String
        var headers: [String: String]
    }

    enum Route {
        case reply(Data)
        /// Takes the request and never answers.
        case hang
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var routes: [String: Route] = [:]
    private let listener: Int32
    let port: Int

    /// `ipv6` listens on ::1 instead of 127.0.0.1.
    init(ipv6: Bool = false) throws {
        listener = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        let fd = listener
        func bindAndName<Address>(_ address: inout Address) -> Bool {
            var len = socklen_t(MemoryLayout<Address>.size)
            return withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                    bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
                }
            }
        }
        let bound: Bool
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_loopback
            bound = bindAndName(&addr)
            port = Int(UInt16(bigEndian: addr.sin6_port))
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            bound = bindAndName(&addr)
            port = Int(UInt16(bigEndian: addr.sin_port))
        }
        guard bound, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Threads of their own, not the global queue: a run makes more of these than its 64 threads,
        // and each sits in accept for good. They last as long as the test process does.
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

    func route(_ path: String, status: String = "200 OK", type: String? = "text/plain", headers: [String] = [], body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        for header in headers { head += header + "\r\n" }
        lock.withLock { routes[path] = .reply(Data((head + "\r\n").utf8) + body) }
    }

    func route(_ path: String, status: String = "200 OK", type: String? = "text/plain", headers: [String] = [], _ body: String = "") {
        route(path, status: status, type: type, headers: headers, body: Data(body.utf8))
    }

    func hang(_ path: String) { lock.withLock { routes[path] = .hang } }

    private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                close(client)
                return
            }
            data.append(buffer, count: count)
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let line = lines.first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.withLock { recorded.append(Request(line: line, headers: headers)) }
        switch lock.withLock({ routes[path] }) {
        case .hang?:
            // Held open until the client goes away.
            _ = read(client, &buffer, buffer.count)
        case .reply(let reply)?:
            reply.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = write(client, raw.baseAddress! + sent, raw.count - sent)
                    guard count > 0 else { break }
                    sent += count
                }
            }
        case nil:
            let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
        }
        close(client)
    }
}

private let onLoopback = BuiltInFetcher(floor: .loopback)

private func text(_ answer: BuiltInAnswer, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    if case .text(let value) = answer { return value }
    Issue.record("expected text, got \(answer)", sourceLocation: sourceLocation)
    return ""
}

private func error(_ answer: BuiltInAnswer, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    if case .error(let value) = answer { return value }
    Issue.record("expected an error, got \(answer)", sourceLocation: sourceLocation)
    return ""
}

@Suite struct BuiltInFetchAddressTests {
    @Test(arguments: ["ftp://a.example/", "file:///etc/passwd", "javascript:alert(1)", "data:text/plain,x", "about:blank", "example.com",
                      "http://", "http:///path", "//example.com/", "", "http://user@example.com/", "http://user:pw@example.com/", "http://@example.com/"])
    func refusedBeforeAnyLookup(_ address: String) {
        #expect(BuiltInFetcher.parse(address) == nil)
    }

    /// `URL.host` would decode these past IDNA, into a lookalike on the card.
    @Test(arguments: ["https://ex%D0%B0mple.org/", "https://%D7%90.org/", "https://a%20b.org/", "http://%31%32%37.0.0.1/"])
    func aPercentEncodedHostIsRefused(address: String) {
        #expect(BuiltInFetcher.parse(address) == nil)
    }

    @Test func aNameWithLettersFromAnotherScriptBecomesItsASCIIForm() throws {
        let url = try #require(BuiltInFetcher.parse("https://ex\u{0430}mple.org/"))
        #expect(url.host == "xn--exmple-4nf.org")
    }

    @Test func aFragmentNeverLeaves() throws {
        let url = try #require(BuiltInFetcher.parse("  https://Example.org/a?b=c#secret \n"))
        #expect(url.absoluteString == "https://Example.org/a?b=c")
    }

    @Test func aNonASCIIAddressIsStillAnAddress() throws {
        let url = try #require(BuiltInFetcher.parse("https://example.org/路径?q=日本"))
        #expect(url.host == "example.org")
    }

    /// The whole point of the default: none of these is even connected to.
    @Test(arguments: [
        "127.0.0.1", "127.8.8.8", "localhost", "LOCALHOST", "a.localhost", "[::1]", "[::ffff:127.0.0.1]", "[64:ff9b::7f00:1]", "[2002:7f00:1::]",
        "0.0.0.0", "[::]", "2130706433", "0x7f.1", "127.1", "017700000001",
        "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "[fe80::1]", "[fd00::1]", "[::ffff:192.168.1.1]", "[64:ff9b::c0a8:101]",
        "nas.local", "router.lan", "box.internal", "printer",
        "100.64.0.1", "100.100.100.100", "100.127.255.254", "[fd7a:115c:a1e0::1]",
    ])
    func theDefaultRefuses(_ host: String) async {
        let answer = await BuiltInFetcher().fetch("http://\(host)/")
        #expect(error(answer).contains("was refused"))
    }

    @Test func theDefaultNeverConnectsToThisMac() async throws {
        let web = try LoopbackWeb()
        web.route("/", "secret")
        let answer = await BuiltInFetcher().fetch(web.origin + "/")
        #expect(error(answer).contains("was refused"))
        #expect(!error(answer).contains("secret"))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(web.requests.isEmpty)
    }
}

@Suite struct BuiltInFetchTests {
    @Test func aPageIsFetchedWithNothingOfTheUserInTheRequest() async throws {
        let web = try LoopbackWeb()
        web.route("/page", type: "text/plain; charset=utf-8", "hello 世界")
        let answer = await onLoopback.fetch(web.origin + "/page#frag")
        #expect(text(answer) == "URL: \(web.origin)/page\nType: text/plain\n\nhello 世界")

        let request = try #require(web.requests.first)
        #expect(web.requests.count == 1)
        #expect(request.line == "GET /page HTTP/1.1")
        #expect(request.headers["user-agent"] == "Parley")
        #expect(request.headers["accept-language"] == "en")
        let sent = Set(request.headers.keys)
        #expect(sent.isSubset(of: ["host", "user-agent", "accept-language", "accept", "accept-encoding", "connection"]), "\(sent)")
    }

    @Test func htmlBecomesText() async throws {
        let web = try LoopbackWeb()
        web.route("/", type: "text/html; charset=utf-8", "<html><title>T</title><script>x()</script><p>Body &amp; soul</p></html>")
        #expect(text(await onLoopback.fetch(web.origin + "/")).hasSuffix("\n\nT\n\nBody & soul"))
    }

    @Test(arguments: ["application/json", "application/xml", "application/ld+json", "image/svg+xml", "text/csv", "text/markdown"])
    func textTypesPassAsTheyAre(_ type: String) async throws {
        let web = try LoopbackWeb()
        web.route("/", type: type, #"{"a": "<b>"}"#)
        #expect(text(await onLoopback.fetch(web.origin + "/")).hasSuffix(#"{"a": "<b>"}"#))
    }

    @Test func theCharsetHeaderDecidesTheDecoding() async throws {
        let web = try LoopbackWeb()
        web.route("/latin", type: "text/plain; charset=iso-8859-1", body: Data([0x63, 0x61, 0x66, 0xE9]))
        web.route("/none", type: "text/plain", body: Data([0x63, 0xFF]))
        web.route("/bogus", type: "text/plain; charset=nonsense", "plain")
        #expect(text(await onLoopback.fetch(web.origin + "/latin")).hasSuffix("café"))
        #expect(text(await onLoopback.fetch(web.origin + "/none")).hasSuffix("c\u{FFFD}"))
        #expect(text(await onLoopback.fetch(web.origin + "/bogus")).hasSuffix("plain"))
    }

    private static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding("gbk" as CFString)))
    private static let chinese = "中文网页内容".data(using: gbk)!

    @Test func oneBadByteCostsItsOwnPieceAndNotThePage() throws {
        var body = Data("<p>".utf8)
        body.append(Self.chinese)
        body.append(Data("</p><p>x".utf8))
        body.append(0xFF)
        body.append(Data("</p><p>".utf8))
        body.append(Self.chinese)
        body.append(Data("</p>".utf8))
        let decoded = BuiltInFetcher.decode(body, charset: "gbk", wasCut: false)
        #expect(HTMLText.plain(decoded) == "中文网页内容\n\n\u{FFFD}\n\n中文网页内容")
    }

    @Test func aCutAtTheCapKeepsAllTheText() async throws {
        let web = try LoopbackWeb()
        // One byte first, so the cap lands between the two bytes of a character.
        var body = Data([0x41])
        while body.count < BuiltInFetcher.maxBodyBytes + 100 { body.append(Self.chinese) }
        web.route("/", type: "text/plain; charset=gbk", body: body)
        let page = text(await onLoopback.fetch(web.origin + "/"))
        #expect(page.contains("Only the start was read"))
        #expect(page.contains("A中文网页内容"))
        #expect(!page.contains("\u{FFFD}"))
    }

    @Test func gb2312IsReadAsGBK() throws {
        let body = try #require("朱镕基喆中文".data(using: Self.gbk))
        #expect(BuiltInFetcher.decode(body, charset: "gb2312", wasCut: false) == "朱镕基喆中文")
        #expect(BuiltInFetcher.decode(body, charset: "GB2312", wasCut: false) == "朱镕基喆中文")
    }

    @Test func onlyARealCutDropsTrailingBytes() {
        #expect(BuiltInFetcher.decode(Data([0x61, 0xFF, 0x62]), charset: "utf-8", wasCut: false) == "a\u{FFFD}b")
        #expect(BuiltInFetcher.decode(Data([0x61, 0xFF, 0x62]), charset: "utf-8", wasCut: true) == "a\u{FFFD}b")
        var uncut = Data("中".data(using: Self.gbk)!)
        uncut.append(0xFF)
        #expect(BuiltInFetcher.decode(uncut, charset: "gbk", wasCut: false) == "\u{FFFD}")
        #expect(BuiltInFetcher.decode(uncut, charset: "gbk", wasCut: true) == "中")
    }

    @Test func aBinaryTypeIsNamedAndItsBodyDropped() async throws {
        let web = try LoopbackWeb()
        web.route("/", type: "image/png", "PNGSECRET")
        let message = error(await onLoopback.fetch(web.origin + "/"))
        #expect(message == "Not a text page: image/png, 9 bytes. Nothing was read.")
    }

    @Test(arguments: [("404 Not Found", 404), ("500 Oops", 500), ("304 Not Modified", 304), ("401 Unauthorized", 401)])
    func aStatusOutside2xxIsAnError(_ status: String, _ code: Int) async throws {
        let web = try LoopbackWeb()
        web.route("/", status: status, "BODYSECRET")
        #expect(error(await onLoopback.fetch(web.origin + "/")) == "The server answered HTTP \(code).")
    }

    @Test func aBodyOverTheCapIsCutAndSaysSo() async throws {
        let web = try LoopbackWeb()
        web.route("/", body: Data(repeating: 0x61, count: BuiltInFetcher.maxBodyBytes + 1_000_000))
        let page = text(await onLoopback.fetch(web.origin + "/"))
        #expect(page.contains("Note: this page is larger than 2 MiB. Only the start was read."))
        #expect(page.filter { $0 == "a" }.count >= BuiltInFetcher.maxBodyBytes)
        #expect(page.utf8.count < BuiltInFetcher.maxBodyBytes + 300)
    }

    @Test func aBodyOfExactlyTheCapIsWhole() async throws {
        let web = try LoopbackWeb()
        web.route("/", body: Data(repeating: 0x61, count: BuiltInFetcher.maxBodyBytes))
        #expect(!text(await onLoopback.fetch(web.origin + "/")).contains("Note:"))
    }

    @Test func aRefusedConnectionIsAnError() async throws {
        #expect(error(await onLoopback.fetch("http://127.0.0.1:\(try mcpFreePort())/")).contains("failed"))
    }
}

@Suite struct BuiltInFetchRedirectTests {
    @Test(arguments: ["301 Moved", "302 Found", "303 See Other", "307 Temporary", "308 Permanent"])
    func aRedirectInTheSameOriginIsFollowed(_ status: String) async throws {
        let web = try LoopbackWeb()
        web.route("/old", status: status, headers: ["Location: /new"])
        web.route("/new", "arrived")
        let page = text(await onLoopback.fetch(web.origin + "/old"))
        #expect(page.hasPrefix("URL: \(web.origin)/new\n"))
        #expect(page.hasSuffix("arrived"))
        #expect(web.requests.map(\.line) == ["GET /old HTTP/1.1", "GET /new HTTP/1.1"])
    }

    @Test func relativeAndAbsoluteTargetsBothWork() async throws {
        let web = try LoopbackWeb()
        web.route("/a/b", status: "302 Found", headers: ["Location: c"])
        web.route("/a/c", status: "302 Found", headers: ["Location: \(web.origin)/d#frag"])
        web.route("/d", "end")
        #expect(text(await onLoopback.fetch(web.origin + "/a/b")).hasSuffix("end"))
    }

    @Test func fiveAreFollowedAndTheSixthIsNot() async throws {
        let web = try LoopbackWeb()
        for hop in 0..<6 { web.route("/\(hop)", status: "302 Found", headers: ["Location: /\(hop + 1)"]) }
        web.route("/6", "unreachable")
        #expect(error(await onLoopback.fetch(web.origin + "/0")).contains("Too many redirects"))
        #expect(web.requests.count == 6)

        let short = try LoopbackWeb()
        for hop in 0..<5 { short.route("/\(hop)", status: "302 Found", headers: ["Location: /\(hop + 1)"]) }
        short.route("/5", "reached")
        #expect(text(await onLoopback.fetch(short.origin + "/0")).hasSuffix("reached"))
    }

    @Test func anotherPortIsNotFollowedAndIsNeverContacted() async throws {
        let web = try LoopbackWeb()
        let other = try LoopbackWeb()
        other.route("/x", "other")
        web.route("/", status: "302 Found", headers: ["Location: \(other.origin)/x"])
        let answer = text(await onLoopback.fetch(web.origin + "/"))
        #expect(answer.contains("redirects to \(other.origin)/x"))
        #expect(answer.contains("call fetch_url with that address"))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(other.requests.isEmpty)
    }

    @Test func anUpgradeToHTTPSIsANewCard() async throws {
        let web = try LoopbackWeb()
        let target = "https://127.0.0.1:\(web.port)/page"
        web.route("/page", status: "301 Moved", headers: ["Location: \(target)"])
        #expect(text(await onLoopback.fetch(web.origin + "/page")).contains("redirects to \(target)"))
        #expect(web.requests.count == 1)
    }

    @Test func anotherHostIsReported() async throws {
        let web = try LoopbackWeb()
        web.route("/", status: "302 Found", headers: ["Location: http://localhost:\(web.port)/"])
        #expect(text(await onLoopback.fetch(web.origin + "/")).contains("redirects to http://localhost:\(web.port)/"))
        #expect(web.requests.count == 1)
    }

    @Test func aTargetWithUserinfoOrAnotherSchemeIsNotFollowed() async throws {
        let web = try LoopbackWeb()
        web.route("/a", status: "302 Found", headers: ["Location: http://user:pw@127.0.0.1:\(web.port)/x"])
        web.route("/b", status: "302 Found", headers: ["Location: file:///etc/passwd"])
        #expect(text(await onLoopback.fetch(web.origin + "/a")).contains("redirects to"))
        // URLSession itself refuses this one, before the delegate. It goes no further either way.
        #expect(error(await onLoopback.fetch(web.origin + "/b")).contains("failed"))
        #expect(web.requests.count == 2)
    }

    @Test func noLocationIsAnError() async throws {
        let web = try LoopbackWeb()
        web.route("/", status: "302 Found")
        #expect(error(await onLoopback.fetch(web.origin + "/")).contains("HTTP 302"))
    }

    @Test func eachHopIsCheckedAgain() async throws {
        let web = try LoopbackWeb()
        web.route("/", status: "302 Found", headers: ["Location: /next"])
        web.route("/next", "SECRET")
        // Connects, then the connection check refuses the first hop: the second never happens.
        let answer = await BuiltInFetcher(floor: .loopback, connectionFloor: .remote).fetch(web.origin + "/")
        #expect(error(answer).contains("The connection to 127.0.0.1 failed."))
        #expect(web.requests.count == 1)
    }
}

/// A name that looked public and connected to a private address, played by a loopback connection
/// held to the public floor. The GET does arrive (the documented limit); the answer must go no further.
@Suite struct BuiltInFetchConnectionCheckTests {
    private let rebound = BuiltInFetcher(floor: .loopback, connectionFloor: .remote)

    @Test func aWholeBodyIsThrownAway() async throws {
        let web = try LoopbackWeb()
        web.route("/", "BODYSECRET")
        let message = error(await rebound.fetch(web.origin + "/"))
        #expect(message.contains("The connection to 127.0.0.1 failed."))
        #expect(!message.contains("BODYSECRET"))
        #expect(web.requests.count == 1)
    }

    @Test func aBodyCutAtTheCapIsCheckedToo() async throws {
        let web = try LoopbackWeb()
        web.route("/", body: Data(repeating: 0x61, count: BuiltInFetcher.maxBodyBytes + 1_000_000))
        #expect(error(await rebound.fetch(web.origin + "/")).contains("The connection to 127.0.0.1 failed."))
    }

    @Test func aStatusIsNotReported() async throws {
        let web = try LoopbackWeb()
        web.route("/", status: "403 Forbidden", "x")
        #expect(error(await rebound.fetch(web.origin + "/")).contains("The connection to 127.0.0.1 failed."))
    }

    @Test func aRedirectTargetIsNotReported() async throws {
        let web = try LoopbackWeb()
        web.route("/", status: "302 Found", headers: ["Location: https://secret.example/admin"])
        let message = error(await rebound.fetch(web.origin + "/"))
        #expect(message.contains("The connection to 127.0.0.1 failed."))
        #expect(!message.contains("secret.example"))
    }

    /// The two checks over IPv6, where URLSession reports the address in a form of its own. Most
    /// large sites answer on IPv6, so a form the check cannot read would refuse them all.
    @Test func anIPv6ConnectionIsReadAndChecked() async throws {
        let web = try LoopbackWeb(ipv6: true)
        web.route("/", "over six")
        #expect(text(await onLoopback.fetch("http://[::1]:\(web.port)/")).hasSuffix("over six"))
        let refused = error(await rebound.fetch("http://[::1]:\(web.port)/"))
        #expect(refused.contains("failed"))
        #expect(!refused.contains("over six"))
    }

    /// On a rebound name the kind of failure would be a port scan, one approved call at a time.
    @Test func anOpenPortAndAClosedOneReadTheSame() async throws {
        let web = try LoopbackWeb()
        web.route("/", "x")
        let open = error(await rebound.fetch(web.origin + "/"))
        let closed = error(await rebound.fetch("http://127.0.0.1:\(try mcpFreePort())/"))
        let notTLS = error(await rebound.fetch("https://127.0.0.1:\(web.port)/"))
        #expect(open == "The connection to 127.0.0.1 failed.")
        #expect(closed == open)
        #expect(notTLS == open)
    }

    /// Refused before anything was sent, so it can say why.
    @Test func theCheckBeforeConnectingKeepsItsExplanation() async {
        #expect(error(await BuiltInFetcher().fetch("http://10.0.0.1/")).contains("was refused"))
    }

    @Test func aBinaryTypeIsNotReported() async throws {
        let web = try LoopbackWeb()
        web.route("/", type: "application/x-internal", "x")
        let message = error(await rebound.fetch(web.origin + "/"))
        #expect(message.contains("The connection to 127.0.0.1 failed."))
        #expect(!message.contains("x-internal"))
    }
}

@Suite struct BuiltInFetchCallTests {
    private func runner(_ web: LoopbackWeb? = nil) -> BuiltInToolRunner {
        BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["fetch_url"]) }, fetcher: onLoopback)
    }

    private var tool: MCPTool { BuiltInTools.Tool.fetchURL.definition }

    @Test func aCallEndsAsAnMCPCallDoes() async throws {
        let web = try LoopbackWeb()
        web.route("/", "hello")
        let result = await runner().call(tool, arguments: ["url": .string(web.origin + "/")], timeout: 10, maxCharacters: 1000)
        #expect(result.callStatus == .completed)
        #expect(result.text.hasSuffix("hello"))

        let refused = await runner().call(tool, arguments: ["url": .string("ftp://a/")], timeout: 10, maxCharacters: 1000)
        #expect(refused.callStatus == .toolError)
        let missing = await runner().call(tool, arguments: [:], timeout: 10, maxCharacters: 1000)
        #expect(missing.callStatus == .toolError)
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let web = try LoopbackWeb()
        web.hang("/")
        let start = Date()
        let result = await runner().call(tool, arguments: ["url": .string(web.origin + "/")], timeout: 0.3, maxCharacters: 1000)
        #expect(result.callStatus == .timedOut)
        #expect(result.text == ToolResultText.timedOut(seconds: 0.3))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func stopInterruptsAFetchAtOnce() async throws {
        let web = try LoopbackWeb()
        web.hang("/")
        let runner = runner()
        let tool = tool
        let url = web.origin + "/"
        let task = Task { await runner.call(tool, arguments: ["url": .string(url)], timeout: 60, maxCharacters: 1000) }
        #expect(await eventually { !web.requests.isEmpty })
        let start = Date()
        task.cancel()
        let result = await task.value
        #expect(result.callStatus == .cancelled)
        #expect(result.text == ToolResultText.interrupted)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
