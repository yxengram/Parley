import Foundation
import Testing
@testable import ParleyCore

// Servers behind Cloudflare (a Cloudflare Tunnel or a proxied hostname): Cloudflare's own error
// pages are stored as one readable line, the origin's errors that merely pass through Cloudflare
// are left alone, and a reply cut off mid-stream is reported as interrupted. Network tests only
// talk to tools/mock_server.py on 127.0.0.1 (its /cf… path prefixes play Cloudflare's edge).

private let cfHeaders = ["server": "cloudflare", "cf-ray": "a54c823f3e275e92-BNE"]

private func page(title: String, body: String = "", css: Int = 4000) -> Data {
    let style = String(repeating: ".cf-rule{margin:0 auto;padding:4px}", count: css / 36)
    return Data("""
    <!DOCTYPE html>
    <html class="no-js" lang="en-US"><head><title>\(title)</title>
    <link rel="stylesheet" href="/cdn-cgi/styles/main.css" /><style>\(style)</style></head>
    <body><div id="cf-wrapper"><div id="cf-error-details">\(body)
    <span class="cf-footer-item">Cloudflare Ray ID: <strong class="font-semibold">8f1a2b3c4d5e6f70</strong></span>
    </div></div></body></html>
    """.utf8)
}

@Suite struct CloudflareParserTests {
    @Test func edgePagesBecomeOneLine() throws {
        let timeout = try #require(CloudflareError.detect(
            status: 524, headers: cfHeaders,
            body: page(title: "strata.example.net | 524: A timeout occurred",
                       body: #"<h1><span>A timeout occurred</span> <span class="code-label">Error code 524</span></h1>"#)))
        #expect(timeout.kind == .timeout && timeout.code == 524)
        #expect(timeout.summary == "Cloudflare error 524: A timeout occurred · Ray ID a54c823f3e275e92-BNE")

        // The tunnel page: the code sits after several KB of CSS, the title names the error.
        let tunnel = try #require(CloudflareError.detect(
            status: 530, headers: cfHeaders,
            body: page(title: "Cloudflare Tunnel error | strata.example.net | Cloudflare",
                       body: #"<h1><span class="cf-error-type">Error</span><span class="cf-error-code">1033</span></h1>"#, css: 9000)))
        #expect(tunnel.kind == .tunnelDown && tunnel.code == 1033 && tunnel.title == "Cloudflare Tunnel error")

        // Cloudflare's plain-text answer for API clients.
        let plain = try #require(CloudflareError.detect(status: 530, headers: cfHeaders, body: Data("error code: 1033".utf8)))
        #expect(plain.kind == .tunnelDown && plain.title == nil)
        let limited = try #require(CloudflareError.detect(status: 429, headers: cfHeaders, body: Data("error code: 1015".utf8)))
        #expect(limited.kind == .rateLimited)

        // A browser challenge says so in a header.
        var challengeHeaders = cfHeaders
        challengeHeaders["cf-mitigated"] = "challenge"
        let challenge = try #require(CloudflareError.detect(
            status: 403, headers: challengeHeaders,
            body: Data("<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script src=\"/cdn-cgi/challenge-platform/x\"></script></body></html>".utf8)))
        #expect(challenge.kind == .challenge && challenge.summary.hasPrefix("Cloudflare challenge: Just a moment..."))
        let block = try #require(CloudflareError.detect(
            status: 403, headers: cfHeaders,
            body: page(title: "Attention Required! | Cloudflare", body: #"<span class="cf-error-code">1020</span>"#)))
        #expect(block.kind == .challenge && block.code == 1020)

        let bad = try #require(CloudflareError.detect(status: 502, headers: cfHeaders,
                                                      body: page(title: "strata.example.net | 502: Bad gateway")))
        #expect(bad.kind == .originUnreachable)
        for (status, kind) in [(520, CloudflareError.Kind.originUnreachable), (521, .originUnreachable), (522, .originUnreachable),
                               (523, .originUnreachable), (525, .originTLS), (526, .originTLS), (504, .originUnreachable)] {
            let e = try #require(CloudflareError.detect(status: status, headers: cfHeaders, body: page(title: "x.example | \(status): Something")))
            #expect(e.kind == kind, "\(status)")
        }
    }

    // Behind a tunnel every response has Cloudflare's headers, the origin's own errors included.
    @Test func originErrorsThroughCloudflareStayTheOrigins() {
        let overflow = #"{"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (600052 tokens) leaves no room to answer in the context (131072); requests are never truncated"}}"#
        #expect(CloudflareError.detect(status: 400, headers: cfHeaders, body: Data(overflow.utf8)) == nil)
        #expect(CloudflareError.detect(status: 401, headers: cfHeaders, body: Data(#"{"error":"Invalid API key"}"#.utf8)) == nil)
        #expect(CloudflareError.detect(status: 404, headers: cfHeaders, body: Data("Not found".utf8)) == nil)
        #expect(CloudflareError.detect(status: 500, headers: cfHeaders, body: Data("Request failed".utf8)) == nil)
        #expect(CloudflareError.detect(status: 502, headers: cfHeaders, body: Data(#"{"error":{"message":"fetch failed"}}"#.utf8)) == nil)
        // Without Cloudflare, a 52x is just a status.
        #expect(CloudflareError.detect(status: 524, headers: [:], body: Data()) == nil)
        // nginx's page is not Cloudflare's.
        #expect(CloudflareError.detect(status: 502, headers: [:],
                                       body: Data("<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx</center></body></html>".utf8)) == nil)
    }

    @Test func accessRedirectKeepsOnlyTheHost() throws {
        let location = "https://team.cloudflareaccess.com/cdn-cgi/access/login/strata.example.net?kid=abc&redirect_url=%2Fv1%2Fmodels"
        let access = try #require(CloudflareError.detect(status: 302, headers: cfHeaders.merging(["location": location]) { $1 }, body: Data()))
        #expect(access.kind == .access)
        #expect(access.summary == "Cloudflare Access sign-in at team.cloudflareaccess.com (redirect not followed)")
        #expect(!access.summary.contains("kid") && !access.summary.contains("redirect_url"))
        // Another redirect is not Access.
        #expect(CloudflareError.detect(status: 301, headers: cfHeaders.merging(["location": "https://strata.example.net/v1/models"]) { $1 }, body: Data()) == nil)
    }

    @Test func storedLinesParseBack() throws {
        for error in [
            CloudflareError(status: 524, code: 524, title: "A timeout occurred", rayID: "a54c823f3e275e92-BNE"),
            CloudflareError(status: 530, code: 1033, title: "Cloudflare Tunnel error"),
            CloudflareError(status: 530, code: 1033),
            CloudflareError(status: 403, title: "Just a moment...", isChallenge: true),
            CloudflareError(status: 302, accessHost: "team.cloudflareaccess.com"),
        ] {
            #expect(CloudflareError.parse(status: error.status, body: error.summary) == error, "\(error.summary)")
        }
        // Conversations saved before: the raw page, cut to 2000 characters, still reads as Cloudflare's.
        let old = String(decoding: page(title: "strata.example.net | 524: A timeout occurred", css: 6000), as: UTF8.self)
        let parsed = try #require(CloudflareError.parse(status: 524, body: String(old.prefix(2000))))
        #expect(parsed.kind == .timeout && parsed.title == "A timeout occurred")
        #expect(CloudflareError.parse(status: 530, body: "error code: 1033")?.kind == .tunnelDown)
        #expect(CloudflareError.parse(status: 400, body: #"{"error":"x"}"#) == nil)
        #expect(CloudflareError.parse(status: 500, body: "Request failed") == nil)
    }

    @Test func htmlBodiesAreSummarized() {
        let nginx = Data("<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n<body>\r\n<center><h1>502 Bad Gateway</h1></center>\r\n</body>\r\n</html>".utf8)
        #expect(ResponseText.errorBody(status: 502, response: nil, data: nginx) == "502 Bad Gateway")
        #expect(ResponseText.errorBody(status: 500, response: nil, data: Data("<html><body><p>oops</p></body></html>".utf8)) == "HTML page")
        #expect(ResponseText.errorBody(status: 400, response: nil, data: Data(#"{"error":"x"}"#.utf8)) == #"{"error":"x"}"#)
        #expect(ResponseText.plainText("A &amp; B&nbsp;<b>c</b>") == "A & B c")
    }

    // Cloudflare's JS detection injects /cdn-cgi/challenge-platform/… into the origin's own pages:
    // an ordinary 404 from the server behind the tunnel is not a challenge.
    @Test func originPagesWithCloudflareScriptsAreNotChallenges() throws {
        let origin404 = Data("""
        <!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1>
        <script>(function(){var a=document.createElement('script');a.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js';document.head.appendChild(a)})();</script>
        </body></html>
        """.utf8)
        #expect(CloudflareError.detect(status: 404, headers: cfHeaders, body: origin404) == nil)
        #expect(CloudflareError.parse(status: 404, body: String(decoding: origin404, as: UTF8.self)) == nil)
        #expect(ResponseText.errorBody(status: 404, response: nil, data: origin404) == "404 Not Found")
        // A 1020 block page that carries the same script keeps its code in the stored line.
        let block = try #require(CloudflareError.detect(
            status: 403, headers: cfHeaders,
            body: page(title: "Attention Required! | Cloudflare",
                       body: #"<span class="cf-error-code">1020</span><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>"#)))
        #expect(block.kind == .challenge && !block.isChallenge && block.code == 1020)
        #expect(block.summary.hasPrefix("Cloudflare error 1020: Attention Required!"))
        // The interstitial itself (stored, so without its header) still reads as a challenge.
        let interstitial = "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt={cType:'managed'};</script></body></html>"
        #expect(CloudflareError.parse(status: 403, body: interstitial)?.kind == .challenge)
        #expect(CloudflareError.parse(status: 404, body: interstitial) == nil)
    }

    // Cloudflare's plain answer is the whole body, and live it comes with Cloudflare's headers.
    @Test func plainErrorCodeNeedsTheWholeBodyAndCloudflare() {
        let traceback = Data("Traceback (most recent call last):\nerror code: 500\n".utf8)
        #expect(CloudflareError.detect(status: 500, headers: [:], body: traceback) == nil)
        #expect(CloudflareError.detect(status: 500, headers: cfHeaders, body: traceback) == nil)
        #expect(CloudflareError.detect(status: 530, headers: [:], body: Data("error code: 1033".utf8)) == nil)
        #expect(CloudflareError.detect(status: 429, headers: cfHeaders, body: Data("error code: 1015\n".utf8))?.kind == .rateLimited)
        #expect(CloudflareError.parse(status: 500, body: "Traceback (most recent call last):\nerror code: 500") == nil)
        #expect(CloudflareError.parse(status: 530, body: "error code: 1033")?.code == 1033)
    }

    @Test func jsonQuotingMarkupStaysJSON() {
        let body = #"{"error":{"message":"Invalid content: <title>x</title> in message"}}"#
        #expect(ResponseText.errorBody(status: 400, response: nil, data: Data(body.utf8)) == body)
        #expect(!ResponseText.isHTMLPage(body))
        #expect(CloudflareError.detect(status: 400, headers: cfHeaders, body: Data(body.utf8)) == nil)
    }

    // cloudflared answers an empty 502/504 when it cannot reach the origin.
    @Test func emptyEdgeGatewayIsOriginUnreachable() throws {
        for status in [502, 504] {
            let e = try #require(CloudflareError.detect(status: status, headers: cfHeaders, body: Data()))
            #expect(e.kind == .originUnreachable && e.summary == "Cloudflare error \(status) · Ray ID a54c823f3e275e92-BNE")
            #expect(CloudflareError.parse(status: status, body: e.summary)?.kind == .originUnreachable)
        }
        #expect(CloudflareError.detect(status: 502, headers: [:], body: Data()) == nil)
        #expect(CloudflareError.detect(status: 502, headers: cfHeaders, body: Data("Bad Gateway".utf8)) == nil)
        #expect(CloudflareError.detect(status: 500, headers: cfHeaders, body: Data()) == nil)
    }

    // GET /v1/models as Strata's shared port answers through the Cloudflare Tunnel (shape of a live capture).
    @Test func strataInstanceIDIsRead() throws {
        let list = try JSONSerialization.jsonObject(with: Data(#"""
        {"object":"list","data":[{"id":"iq3_s","object":"model","owned_by":"strata","meta":{"instanceId":"0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a","gpus":[0],"label":"Qwen3.8-Flash-Next IQ3_S","aliases":["iq3_s","qwen-flash"]}}]}
        """#.utf8))
        let info = try #require(ChatClient.parseModelList(list, model: "iq3_s"))
        #expect(info.serverKind == .strata && info.serverInstanceID == "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a")
        #expect(info.loadedContextLength == nil)
        // An alias reaches the same instance.
        #expect(ChatClient.parseModelList(list, model: "qwen-flash")?.serverInstanceID == "0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a")
        var merged = ModelContextInfo(model: "iq3_s")
        merged.merge(info)
        #expect(merged.serverInstanceID == info.serverInstanceID)
    }

    @Test func interruptionTextRoundTrips() {
        let viaCF = StreamInterruption.message(underlying: "The network connection was lost.", viaCloudflare: true)
        #expect(StreamInterruption.parse("API error: " + viaCF)! == (true, "The network connection was lost."))
        #expect(StreamInterruption.parse(StreamInterruption.message(underlying: nil, viaCloudflare: false))! == (false, nil))
        #expect(StreamInterruption.parse("API error: mock stream error") == nil)
        // The no-/v1 hint is about endpoints, not broken streams.
        let bare = try! ChatClient(baseURL: "http://127.0.0.1:1", apiKey: nil)
        #expect(bare.withPathHint(ParleyError.api(viaCF)) as? ParleyError == .api(viaCF))
    }
}

// MARK: - Against the mock server

private let python3Path = "/usr/bin/python3"
private let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/mock_server.py")

private struct MockError: Error, CustomStringConvertible { let description: String }

private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
    }
    guard ok else { throw POSIXError(.EADDRINUSE) }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Runs `body` with the mock's root URL ("http://127.0.0.1:PORT", no path).
private func withMock(_ flavor: String = "lmstudio", _ body: (String) async throws -> Void) async throws {
    let port = try freePort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python3Path)
    process.arguments = ["-I", "-u", mockServerScript.path, String(port), flavor]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        _ = exited.wait(timeout: .now() + 5)
    }
    let root = "http://127.0.0.1:\(port)"
    // A port can be handed out again in this process: what an earlier server on it refused is not this one's.
    StreamOptionsSupport.forget(baseURL: URL(string: root + "/v1")!)
    let probe = try ChatClient(baseURL: root + "/v1", apiKey: nil)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        guard process.isRunning else { throw MockError(description: "mock server exited") }
        if (try? await probe.listModels()) != nil { return try await body(root) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw MockError(description: "mock server did not start")
}

/// Streams a reply; returns the content received and the error the stream ended with.
private func chat(_ base: String, model: String) async throws -> (String, Error?) {
    let client = try ChatClient(baseURL: base, apiKey: nil)
    var acc = StreamAccumulator()
    do {
        for try await delta in client.streamChat(messages: [Message(role: .user, content: "hello")],
                                                 options: ChatRequestOptions(model: model)) {
            acc.apply(delta)
        }
        acc.finish()
        return (acc.content, nil)
    } catch {
        acc.finish()
        return (acc.content, error)
    }
}

private func httpError(_ error: Error?) -> (Int, String)? {
    guard case .http(let status, let body)? = error as? ParleyError else { return nil }
    return (status, body)
}

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
struct CloudflareIntegrationTests {
    @Test func edgeErrorsAreStoredAsOneLine() async throws {
        try await withMock { root in
            let expected: [(String, Int, CloudflareError.Kind)] = [
                ("cf-524", 524, .timeout), ("cf-530", 530, .tunnelDown), ("cf-1033", 530, .tunnelDown),
                ("cf-502", 502, .originUnreachable), ("cf-521", 521, .originUnreachable), ("cf-522", 522, .originUnreachable),
                ("cf-526", 526, .originTLS), ("cf-challenge", 403, .challenge), ("cf-block", 403, .challenge),
                ("cf-1015", 429, .rateLimited), ("cf-access", 302, .access),
            ]
            for (route, status, kind) in expected {
                let base = "\(root)/\(route)/v1"
                // The chat request…
                let (_, error) = try await chat(base, model: "mock-plain")
                let (s, body) = try #require(httpError(error), "\(route)")
                #expect(s == status, "\(route)")
                #expect(!body.contains("<") && body.count < 200, "\(route): \(body)")
                #expect(CloudflareError.parse(status: s, body: body)?.kind == kind, "\(route): \(body)")
                // …and the model list (Test Connection, the model menu).
                do {
                    _ = try await ChatClient(baseURL: base, apiKey: nil).listModels()
                    Issue.record("\(route): expected an error")
                } catch {
                    let (ls, lbody) = try #require(httpError(error), "\(route)")
                    #expect(ls == status && CloudflareError.parse(status: ls, body: lbody)?.kind == kind, "\(route)")
                }
            }
            // The tunnel page's title and Cloudflare's ray id make it into the line.
            let (_, error) = try await chat("\(root)/cf-530/v1", model: "mock-plain")
            #expect(httpError(error)?.1 == "Cloudflare error 1033: Cloudflare Tunnel error · Ray ID 8f1a2b3c4d5e6f70-SYD")
            // A plain redirect keeps where it pointed, without following it.
            let (_, redirect) = try await chat("\(root)/cf-https/v1", model: "mock-plain")
            #expect(httpError(redirect)?.0 == 301)
            #expect(httpError(redirect)?.1.hasPrefix("Redirect to https://127.0.0.1:") == true)
            // A probe through a broken edge learns nothing and never throws.
            let info = await (try ChatClient(baseURL: "\(root)/cf-524/v1", apiKey: nil)).fetchModelInfo(model: "mock-plain")
            #expect(info == ModelContextInfo(model: "mock-plain"))
        }
    }

    // Through a working tunnel the origin's errors arrive unchanged: Strata's overflow still names its context.
    @Test func originErrorsPassThrough() async throws {
        try await withMock("strata-share") { root in
            let client = try ChatClient(baseURL: "\(root)/cf/v1", apiKey: nil)
            let info = await client.fetchModelInfo(model: "strata-qwen")
            #expect(info.serverKind == .strata && info.serverInstanceID == "inst-0")
            var failure: Error?
            do {
                for try await _ in client.streamChat(messages: [Message(role: .user, content: String(repeating: "word ", count: 8000))],
                                                     options: ChatRequestOptions(model: "strata-qwen")) {}
            } catch { failure = error }
            let (status, body) = try #require(httpError(failure))
            #expect(status == 400 && CloudflareError.parse(status: status, body: body) == nil)
            #expect(ContextBudget.contextLength(fromError: (failure as? ParleyError)?.errorDescription ?? "") == 8192)
            // The same instance as the direct route.
            #expect(await (try ChatClient(baseURL: "\(root)/v1", apiKey: nil)).fetchModelInfo(model: "strata-qwen").serverInstanceID == "inst-0")
        }
    }

    @Test func brokenStreamsAreInterruptions() async throws {
        try await withMock { root in
            // The connection is reset mid-body: the partial text arrives, then a readable error.
            let (dropped, dropError) = try await chat("\(root)/v1", model: "mock-drop")
            #expect(dropped.hasPrefix("Partial answer"))
            guard case .api(let message)? = dropError as? ParleyError, let parsed = StreamInterruption.parse(message) else {
                Issue.record("expected an interruption, got \(String(describing: dropError))")
                return
            }
            #expect(!parsed.viaCloudflare && parsed.underlying != nil)

            // A clean end without finish_reason or [DONE] is not a finished reply either.
            let (cut, cutError) = try await chat("\(root)/cf/v1", model: "mock-cut")
            #expect(cut.hasPrefix("Partial answer"))
            guard case .api(let cutMessage)? = cutError as? ParleyError else {
                Issue.record("expected an interruption, got \(String(describing: cutError))")
                return
            }
            #expect(StreamInterruption.parse(cutMessage)! == (true, nil))

            // Normal replies are untouched, through Cloudflare too.
            let (plain, plainError) = try await chat("\(root)/cf/v1", model: "mock-plain")
            #expect(plainError == nil && plain == #"You said: "hello" (0 images received)"#)
        }
    }
}
