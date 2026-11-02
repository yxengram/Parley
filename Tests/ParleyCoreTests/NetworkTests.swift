import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ParleyCore

// Tests for Streaming.swift, ChatClient.swift and Attachments.swift, plus an integration
// suite that drives ChatClient against tools/mock_server.py.

// MARK: - SSEDecoder

@Suite struct SSEDecoderTests {
    @Test func dataWithAndWithoutSpace() {
        var d = SSEDecoder()
        #expect(d.feed(line: #"data: {"a":1}"#) == [#"{"a":1}"#])
        #expect(d.feed(line: #"data:{"b":2}"#) == [#"{"b":2}"#])
        #expect(d.feed(line: "") == [])
    }

    @Test func ignoresCommentsAndOtherFields() {
        var d = SSEDecoder()
        #expect(d.feed(line: ": keep-alive") == [])
        #expect(d.feed(line: "event: message") == [])
        #expect(d.feed(line: "id: 42") == [])
        #expect(d.feed(line: "retry: 1000") == [])
        #expect(d.feed(line: "") == [])
        #expect(d.finish() == [])
    }

    @Test func doneIsReturnedVerbatim() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: [DONE]") == ["[DONE]"])
        var d2 = SSEDecoder()
        #expect(d2.feed(line: "data:[DONE]") == ["[DONE]"])
    }

    @Test func multiLineDataJoinsUntilBlankLine() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: hello") == [])
        #expect(d.feed(line: "data: world") == [])
        #expect(d.feed(line: "") == ["hello\nworld"])
    }

    @Test func multiLineJSONEmittedOnceComplete() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: {") == [])
        #expect(d.feed(line: #"data: "a": 1}"#) == ["{\n\"a\": 1}"])
        #expect(d.feed(line: "") == [])
    }

    @Test func finishFlushesBuffer() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: partial") == [])
        #expect(d.finish() == ["partial"])
        #expect(d.finish() == [])
    }

    @Test func recoversWhenBlankLineWasDropped() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: hello") == [])
        #expect(d.feed(line: #"data: {"a":1}"#) == ["hello", #"{"a":1}"#])
    }

    // Regression: errors sent outside `data: {"error":...}` were silently dropped, so a failed
    // 200 stream was saved as an empty, "complete" reply.
    private func parseAll(_ lines: [String]) throws -> [ChatDelta] {
        var d = SSEDecoder()
        var out: [ChatDelta] = []
        for payload in lines.flatMap({ d.feed(line: $0) }) + d.finish() {
            if let delta = try ChunkParser.parse(payload) { out.append(delta) }
        }
        return out
    }

    @Test func errorFieldBecomesAPIError() {
        #expect(throws: ParleyError.api("boom")) {
            _ = try parseAll([#"error: {"code":500,"message":"boom","type":"server_error"}"#, ""])
        }
        #expect(throws: ParleyError.api("wrapped")) {
            _ = try parseAll([#"error: {"error":{"message":"wrapped"}}"#])
        }
        #expect(throws: ParleyError.api("plain text failure")) {
            _ = try parseAll(["error: plain text failure"])
        }
    }

    @Test func errorEventDataBecomesAPIError() {
        #expect(throws: ParleyError.api("context length exceeded")) {
            _ = try parseAll(["event: error", #"data: {"message":"context length exceeded"}"#, ""])
        }
        // Blank line dropped (AsyncBytes.lines) and non-JSON data.
        #expect(throws: ParleyError.api("slot unavailable")) {
            _ = try parseAll(["event: error", "data: slot unavailable"])
        }
    }

    @Test func errorEventTypeDoesNotLeakIntoNextEvent() throws {
        var d = SSEDecoder()
        #expect(d.feed(line: "event: message") == [])
        let deltas = try parseAll(["event: message", #"data: {"choices":[{"delta":{"content":"hi"}}]}"#])
        #expect(deltas.map(\.content) == ["hi"])
        // An "event: error" payload is consumed once; the following normal chunk is not wrapped.
        var e = SSEDecoder()
        _ = e.feed(line: "event: error")
        #expect(e.feed(line: #"data: {"message":"x"}"#) == [#"{"error":{"message":"x"}}"#])
        #expect(e.feed(line: #"data: {"choices":[]}"#) == [#"{"choices":[]}"#])
        #expect(e.feed(line: "data: [DONE]") == ["[DONE]"])
    }

    @Test func bareJSONLineIsTreatedAsData() {
        #expect(throws: ParleyError.api("bare failure")) {
            _ = try parseAll([#"{"error":{"message":"bare failure"}}"#])
        }
    }

    @Test func stripsCarriageReturn() {
        var d = SSEDecoder()
        #expect(d.feed(line: "data: {\"a\":1}\r") == [#"{"a":1}"#])
        #expect(d.feed(line: "\r") == [])
    }
}

// MARK: - ChunkParser

@Suite struct ChunkParserTests {
    @Test func content() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        #expect(d == ChatDelta(content: "Hi"))
    }

    @Test func reasoningContent() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"delta":{"reasoning_content":"hmm","content":null}}]}"#)
        #expect(d == ChatDelta(reasoning: "hmm"))
    }

    @Test func reasoningField() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"delta":{"reasoning":"thinking"}}]}"#)
        #expect(d == ChatDelta(reasoning: "thinking"))
    }

    @Test func bothReasoningFieldsAreNotDuplicated() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"delta":{"reasoning_content":"x","reasoning":"x"}}]}"#)
        #expect(d?.reasoning == "x")
    }

    @Test func finishReason() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(d == ChatDelta(finishReason: "stop"))
    }

    @Test func usageOnlyChunkWithEmptyChoices() throws {
        let d = try ChunkParser.parse(#"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}"#)
        #expect(d == ChatDelta(usage: TokenUsage(promptTokens: 5, completionTokens: 7, totalTokens: 12)))
    }

    @Test func nullFieldsYieldNil() throws {
        #expect(try ChunkParser.parse(#"{"choices":[{"delta":{"content":null,"reasoning_content":null},"finish_reason":null}],"usage":null}"#) == nil)
        #expect(try ChunkParser.parse(#"{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
    }

    @Test func errorObjectThrows() {
        #expect(throws: ParleyError.api("boom")) {
            _ = try ChunkParser.parse(#"{"error":{"message":"boom","type":"server_error"}}"#)
        }
        #expect(throws: ParleyError.api("plain")) {
            _ = try ChunkParser.parse(#"{"error":"plain"}"#)
        }
    }

    @Test func objectErrorShapeThrows() {
        #expect(throws: ParleyError.api("model not found")) {
            _ = try ChunkParser.parse(#"{"object":"error","message":"model not found","code":404}"#)
        }
    }

    @Test func nullErrorIsIgnored() throws {
        let d = try ChunkParser.parse(#"{"error":null,"choices":[{"delta":{"content":"ok"}}]}"#)
        #expect(d?.content == "ok")
    }

    @Test func doneAndGarbageYieldNil() throws {
        #expect(try ChunkParser.parse("[DONE]") == nil)
        #expect(try ChunkParser.parse("not json") == nil)
        #expect(try ChunkParser.parse("") == nil)
    }

    @Test func nonStreamingMessageShape() throws {
        let d = try ChunkParser.parse(#"{"choices":[{"message":{"role":"assistant","content":"whole"},"finish_reason":"stop"}]}"#)
        #expect(d?.content == "whole")
        #expect(d?.finishReason == "stop")
    }
}

// MARK: - StreamAccumulator

private func t(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 1_000_000 + seconds) }

@Suite struct StreamAccumulatorTests {
    @Test func thinkTagSplitAcrossChunks() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "<thi"), now: t(0))
        #expect(acc.content == "")
        acc.apply(ChatDelta(content: "nk>abc</th"), now: t(1))
        #expect(acc.isReasoning)
        #expect(acc.reasoning == "abc")
        acc.apply(ChatDelta(content: "ink>\nhello"), now: t(2))
        acc.finish(now: t(3))
        #expect(acc.reasoning == "abc")
        #expect(acc.content == "hello")
        #expect(acc.reasoningStartedAt == t(1))
        #expect(acc.reasoningEndedAt == t(2))
        #expect(acc.reasoningDuration == 1)
        #expect(!acc.isReasoning)
    }

    @Test func byteByByteMatchesChunked() {
        let full = "<think>\nLet me think...\n</think>\n\nThe answer is <b>42</b> & 1 < 2."
        var chunked = StreamAccumulator()
        for piece in ["<thi", "nk>\nLet me", " think...\n</th", "ink>\n\n", "The answer is <b>42</b> & 1 < 2."] {
            chunked.apply(ChatDelta(content: piece))
        }
        chunked.finish()

        var single = StreamAccumulator()
        for ch in full { single.apply(ChatDelta(content: String(ch))) }
        single.finish()

        #expect(chunked.reasoning == "Let me think...\n")
        #expect(chunked.content == "The answer is <b>42</b> & 1 < 2.")
        #expect(single.reasoning == chunked.reasoning)
        #expect(single.content == chunked.content)
    }

    @Test func thinkingTagVariantByteByByte() {
        var acc = StreamAccumulator()
        for ch in "<thinking>plan</thinking>\nDone" { acc.apply(ChatDelta(content: String(ch))) }
        acc.finish()
        #expect(acc.reasoning == "plan")
        #expect(acc.content == "Done")
    }

    @Test func orphanClosingTagReclassifiesContent() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "I need to"), now: t(0))
        #expect(acc.content == "I need to")
        acc.apply(ChatDelta(content: " answer.</th"), now: t(1))
        acc.apply(ChatDelta(content: "ink>\n\nAnswer"), now: t(2))
        acc.apply(ChatDelta(content: " here"), now: t(3))
        acc.finish(now: t(4))
        #expect(acc.reasoning == "I need to answer.")
        #expect(acc.content == "Answer here")
        #expect(acc.reasoningStartedAt == t(0))
        #expect(acc.reasoningEndedAt == t(2))
    }

    @Test func orphanByteByByte() {
        var acc = StreamAccumulator()
        for ch in "The user wants an echo.</think>\nYou said hi" { acc.apply(ChatDelta(content: String(ch))) }
        acc.finish()
        #expect(acc.reasoning == "The user wants an echo.")
        #expect(acc.content == "You said hi")
    }

    @Test func noTags() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "Hello"), now: t(0))
        acc.apply(ChatDelta(content: " world, a < b"), now: t(1))
        acc.finish(now: t(2))
        #expect(acc.content == "Hello world, a < b")
        #expect(acc.reasoning == "")
        #expect(acc.reasoningStartedAt == nil)
        #expect(acc.reasoningEndedAt == nil)
        #expect(acc.reasoningDuration == nil)
        #expect(!acc.isReasoning)
    }

    @Test func reasoningContentThenContentTiming() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(reasoning: "Step 1."), now: t(10))
        #expect(acc.isReasoning)
        acc.apply(ChatDelta(reasoning: " Step 2."), now: t(11))
        acc.apply(ChatDelta(content: ""), now: t(12))
        #expect(acc.isReasoning)
        #expect(acc.reasoningEndedAt == nil)
        acc.apply(ChatDelta(content: "\n\nResult"), now: t(13.5))
        #expect(!acc.isReasoning)
        acc.apply(ChatDelta(content: "!", finishReason: "stop"), now: t(14))
        acc.apply(ChatDelta(usage: TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3)), now: t(15))
        acc.finish(now: t(16))
        #expect(acc.reasoning == "Step 1. Step 2.")
        #expect(acc.content == "Result!")
        #expect(acc.reasoningStartedAt == t(10))
        #expect(acc.reasoningEndedAt == t(13.5))
        #expect(acc.reasoningDuration == 3.5)
        #expect(acc.finishReason == "stop")
        #expect(acc.usage == TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3))
    }

    @Test func reasoningOnlyEndsAtFinish() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(reasoning: "thinking"), now: t(0))
        acc.finish(now: t(5))
        #expect(acc.reasoningEndedAt == t(5))
        #expect(acc.reasoningDuration == 5)
        #expect(!acc.isReasoning)
    }

    @Test func unclosedThinkStaysReasoning() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "<think>abc</thi"), now: t(0))
        acc.finish(now: t(2))
        #expect(acc.reasoning == "abc</thi")
        #expect(acc.content == "")
        #expect(acc.reasoningEndedAt == t(2))
    }

    @Test func heldBackPartialTagFlushedAtFinish() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "a <thi"))
        #expect(acc.content == "a ")
        acc.finish()
        #expect(acc.content == "a <thi")
    }

    @Test func explicitAndInlineReasoningBothAppend() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(reasoning: "x"), now: t(0))
        acc.apply(ChatDelta(content: "<think>y</think>z"), now: t(1))
        acc.finish(now: t(2))
        #expect(acc.reasoning == "xy")
        #expect(acc.content == "z")
        #expect(acc.reasoningStartedAt == t(0))
        #expect(acc.reasoningEndedAt == t(1))
    }

    @Test func tagsAreCaseSensitive() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(content: "<THINK>no</THINK>"))
        acc.finish()
        #expect(acc.content == "<THINK>no</THINK>")
        #expect(acc.reasoning == "")
    }
}

// MARK: - ChatClient (pure parts)

@Suite struct RequestBodyTests {
    private func body(_ messages: [Message], _ options: ChatRequestOptions) -> [String: Any] {
        ChatClient.buildRequestBody(messages: messages, options: options)
    }

    private func apiMessages(_ b: [String: Any]) -> [[String: Any]] {
        b["messages"] as? [[String: Any]] ?? []
    }

    @Test func basicFieldsAndOptionalsOmitted() throws {
        let b = body([Message(role: .user, content: "hi")], ChatRequestOptions(model: "m1"))
        #expect(b["model"] as? String == "m1")
        #expect(b["stream"] as? Bool == true)
        #expect(b["temperature"] == nil)
        #expect(b["max_tokens"] == nil)
        #expect(b["reasoning_effort"] == nil)
        #expect(Set(b.keys) == ["model", "stream", "messages"])
        _ = try JSONSerialization.data(withJSONObject: b)
    }

    @Test func optionalsIncludedWhenSet() {
        let o = ChatRequestOptions(model: "m", temperature: 0.5, maxTokens: 100, reasoningEffort: .high)
        let b = body([Message(role: .user, content: "hi")], o)
        #expect(b["temperature"] as? Double == 0.5)
        #expect(b["max_tokens"] as? Int == 100)
        #expect(b["reasoning_effort"] as? String == "high")
    }

    @Test func optionsFromSettings() {
        let s = ConversationSettings(model: "abc", systemPrompt: "sys", temperature: 0.2, maxTokens: 9, reasoningEffort: .low)
        let o = ChatRequestOptions(settings: s)
        #expect(o.model == "abc")
        #expect(o.systemPrompt == "sys")
        #expect(o.temperature == 0.2)
        #expect(o.maxTokens == 9)
        #expect(o.reasoningEffort == .low)
    }

    @Test func systemPromptFirst() {
        let msgs = [Message(role: .user, content: "q"), Message(role: .assistant, content: "a")]
        let m = apiMessages(body(msgs, ChatRequestOptions(model: "m", systemPrompt: "Be brief.")))
        #expect(m.count == 3)
        #expect(m[0]["role"] as? String == "system")
        #expect(m[0]["content"] as? String == "Be brief.")
        #expect(m[1]["role"] as? String == "user")
        #expect(m[2]["role"] as? String == "assistant")
    }

    @Test func blankSystemPromptOmitted() {
        let m = apiMessages(body([Message(role: .user, content: "q")], ChatRequestOptions(model: "m", systemPrompt: "  \n ")))
        #expect(m.count == 1)
        #expect(m[0]["role"] as? String == "user")
    }

    @Test func reasoningNeverSent() {
        let msgs = [
            Message(role: .user, content: "q"),
            Message(role: .assistant, content: "answer", reasoning: "secret thoughts", reasoningDuration: 3),
        ]
        let b = body(msgs, ChatRequestOptions(model: "m"))
        let m = apiMessages(b)
        #expect(Set(m[1].keys) == ["role", "content"])
        #expect(m[1]["content"] as? String == "answer")
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: b), as: UTF8.self)
        #expect(!json.contains("secret thoughts"))
        #expect(!json.contains("reasoning"))
    }

    @Test func emptyAssistantSkippedPartialKept() {
        let msgs = [
            Message(role: .user, content: "q1"),
            Message(role: .assistant, content: "", isComplete: false, error: "HTTP 500"),
            Message(role: .user, content: "q2"),
            Message(role: .assistant, content: "partial", isComplete: false),
            Message(role: .user, content: "q3"),
        ]
        let m = apiMessages(body(msgs, ChatRequestOptions(model: "m")))
        #expect(m.map { $0["role"] as? String } == ["user", "user", "assistant", "user"])
        #expect(m[2]["content"] as? String == "partial")
    }

    @Test func imagesAsParts() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let msg = Message(role: .user, content: "what is this?", attachments: [
            Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: png),
            Attachment(kind: .image, filename: "b.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3])),
            Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", text: "file body"),
        ])
        let m = apiMessages(body([msg], ChatRequestOptions(model: "m")))
        let parts = try #require(m[0]["content"] as? [[String: Any]])
        #expect(parts.count == 3)
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "what is this?\n\n<file name=\"notes.txt\">\nfile body\n</file>")
        #expect(parts[1]["type"] as? String == "image_url")
        let url1 = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url1 == "data:image/png;base64,\(png.base64EncodedString())")
        let url2 = (parts[2]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url2 == "data:image/jpeg;base64,AQID")
    }

    @Test func textAttachmentWithoutImagesIsString() {
        let msg = Message(role: .user, content: "see file", attachments: [
            Attachment(kind: .text, filename: "a.md", mimeType: "text/markdown", text: "# Title"),
        ])
        let m = apiMessages(body([msg], ChatRequestOptions(model: "m")))
        #expect(m[0]["content"] as? String == "see file\n\n<file name=\"a.md\">\n# Title\n</file>")
    }
}

@Suite struct ChatClientConfigTests {
    @Test func baseURLNormalization() throws {
        let c = try ChatClient(baseURL: "  http://127.0.0.1:1234/v1///  \n", apiKey: nil)
        #expect(c.baseURL.absoluteString == "http://127.0.0.1:1234/v1")
        let c2 = try ChatClient(baseURL: "HTTPS://api.example.com/v1", apiKey: "k")
        #expect(c2.baseURL.host == "api.example.com")
    }

    @Test(arguments: ["", "not a url", "ftp://example.com/v1", "http://", "file:///tmp/x", "example.com/v1"])
    func invalidBaseURLs(_ s: String) {
        #expect(throws: ParleyError.invalidBaseURL(s)) {
            _ = try ChatClient(baseURL: s, apiKey: nil)
        }
    }

    @Test func ephemeralSessionConfiguration() {
        let c = ChatClient.makeConfiguration()
        #expect(c.urlCache == nil)
        #expect(c.httpCookieStorage == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(c.timeoutIntervalForRequest == 600)
    }

    @Test(arguments: [
        "localhost", "LOCALHOST", "localhost.", "foo.localhost", "mac-studio.local",
        "127.0.0.1", "127.255.255.254", "10.0.0.1", "10.255.255.255",
        "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.10.10",
        "100.64.0.1", "100.127.255.255",
        "::1", "[::1]", "fe80::1", "fe80::1%en0", "[fe80::abcd%en0]", "febf::1",
        "fc00::1", "fd12:3456::1", "::ffff:192.168.1.1",
    ])
    func localHosts(_ host: String) {
        #expect(ChatClient.isLocalHost(host))
    }

    @Test(arguments: [
        "", "example.com", "api.openai.com", "localhost.example.com", "10.0.0.1.example.com",
        "local", "notlocal", "8.8.8.8", "172.15.255.255", "172.32.0.1", "192.169.0.1",
        "169.255.0.1", "100.63.255.255", "100.128.0.1", "11.0.0.1", "1.2.3.4",
        "2001:4860:4860::8888", "fec0::1", "fe00::1", "fe7f::1", "::ffff:8.8.8.8", "::",
        "127.1", "999.0.0.1",
    ])
    func nonLocalHosts(_ host: String) {
        #expect(!ChatClient.isLocalHost(host))
    }
}

// MARK: - AttachmentLoader

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-net-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeImage(width: Int, height: Int, alpha: Bool) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    return ctx.makeImage()!
}

private func encodeImage(_ image: CGImage, type: UTType) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
    return out as Data
}

private func pixelSize(of data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
    return (w, h)
}

@Suite struct AttachmentLoaderTests {
    @Test func smallPNGWithAlphaStaysPNG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("icon.png")
        try encodeImage(makeImage(width: 64, height: 48, alpha: true), type: .png).write(to: url)

        #expect(AttachmentLoader.isSupported(url: url))
        let a = try AttachmentLoader.load(url: url)
        #expect(a.kind == .image)
        #expect(a.mimeType == "image/png")
        #expect(a.filename == "icon.png")
        let data = try #require(a.data)
        let size = try #require(pixelSize(of: data))
        #expect(size.0 == 64 && size.1 == 48)
    }

    @Test func largeJPEGIsDownscaled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.jpg")
        try encodeImage(makeImage(width: 3000, height: 2000, alpha: false), type: .jpeg).write(to: url)

        let a = try AttachmentLoader.load(url: url)
        #expect(a.kind == .image)
        #expect(a.mimeType == "image/jpeg")
        let data = try #require(a.data)
        let size = try #require(pixelSize(of: data))
        #expect(max(size.0, size.1) <= AttachmentLoader.maxImageDimension)
        #expect(size.0 == 2048)
        #expect(abs(size.1 - 1365) <= 1)
    }

    @Test func largePNGWithAlphaIsDownscaledAndKeepsAlpha() throws {
        let data = encodeImage(makeImage(width: 4000, height: 1000, alpha: true), type: .png)
        let a = try AttachmentLoader.image(data: data, filename: "wide.png")
        #expect(a.mimeType == "image/png")
        let encoded = try #require(a.data)
        let size = try #require(pixelSize(of: encoded))
        #expect(size.0 == 2048)
        #expect(size.1 == 512)
    }

    @Test func imageFromGarbageThrows() {
        #expect(throws: ParleyError.unsupportedAttachment("x.png")) {
            _ = try AttachmentLoader.image(data: Data([1, 2, 3, 4, 5]), filename: "x.png")
        }
    }

    @Test func textFileRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "hello\nwörld ✓\n"
        for name in ["notes.txt", "README.md", "main.swift", "data.json", "config.yaml", "table.csv", "unknown.zzqq"] {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            #expect(AttachmentLoader.isSupported(url: url), "\(name)")
            let a = try AttachmentLoader.load(url: url)
            #expect(a.kind == .text, "\(name)")
            #expect(a.text == text, "\(name)")
            #expect(a.filename == name)
            #expect(a.data == nil)
            #expect(!a.mimeType.isEmpty)
        }
    }

    @Test func binaryFileRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x41]).write(to: url)
        #expect(!AttachmentLoader.isSupported(url: url))
        #expect(throws: ParleyError.unsupportedAttachment("blob.bin")) {
            _ = try AttachmentLoader.load(url: url)
        }
        // A "text" extension with NUL bytes inside is not text either.
        let fake = dir.appendingPathComponent("fake.txt")
        try Data([0x41, 0x00, 0x42]).write(to: fake)
        #expect(throws: ParleyError.unsupportedAttachment("fake.txt")) {
            _ = try AttachmentLoader.load(url: fake)
        }
    }

    @Test func oversizedTextRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: AttachmentLoader.maxTextBytes + 1).write(to: url)
        #expect(throws: ParleyError.attachmentTooLarge("big.txt")) {
            _ = try AttachmentLoader.load(url: url)
        }
        let unknown = dir.appendingPathComponent("big.zzqq")
        try Data(repeating: 0x61, count: AttachmentLoader.maxTextBytes + 1).write(to: unknown)
        #expect(throws: ParleyError.attachmentTooLarge("big.zzqq")) {
            _ = try AttachmentLoader.load(url: unknown)
        }
        let exact = dir.appendingPathComponent("exact.txt")
        try Data(repeating: 0x61, count: AttachmentLoader.maxTextBytes).write(to: exact)
        #expect(try AttachmentLoader.load(url: exact).text?.count == AttachmentLoader.maxTextBytes)
    }

    @Test func directoryAndMissingFileRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AttachmentLoader.isSupported(url: dir))
        #expect(throws: ParleyError.self) { _ = try AttachmentLoader.load(url: dir) }
        let missing = dir.appendingPathComponent("missing.txt")
        #expect(!AttachmentLoader.isSupported(url: missing))
        #expect(throws: ParleyError.self) { _ = try AttachmentLoader.load(url: missing) }
    }
}

// MARK: - Integration with tools/mock_server.py

private let python3Path = "/usr/bin/python3"

private let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()   // ParleyCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("tools/mock_server.py")

private func freeLocalPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
            bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
        }
    }
    guard bound else { throw POSIXError(.EADDRINUSE) }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// A listening socket on 127.0.0.1 that never answers. Counts connections that reached it.
private final class NonBlockingListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        guard ok, listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: addr.sin_port))
    }

    func acceptedConnections() -> Int {
        var n = 0
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            n += 1
            Darwin.close(c)
        }
        return n
    }

    func close() { Darwin.close(fd) }
}

private struct MockServerError: Error, CustomStringConvertible {
    let description: String
}

/// Starts the mock server on a free port, runs `body` with its base URL, then stops it.
private func withMockServer(_ body: (String) async throws -> Void) async throws {
    guard FileManager.default.fileExists(atPath: mockServerScript.path) else {
        throw MockServerError(description: "mock server not found at \(mockServerScript.path)")
    }
    let port = try freeLocalPort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python3Path)
    process.arguments = ["-I", "-u", mockServerScript.path, String(port)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // waitUntilExit() spins the current run loop and can miss the exit, hanging the suite;
    // wait on the termination handler instead, with a bound.
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        _ = exited.wait(timeout: .now() + 5)
    }

    let baseURL = "http://127.0.0.1:\(port)/v1"
    let probe = try ChatClient(baseURL: baseURL, apiKey: nil)
    let deadline = Date().addingTimeInterval(15)
    var ready = false
    while Date() < deadline {
        guard process.isRunning else {
            throw MockServerError(description: "mock server exited with status \(process.terminationStatus)")
        }
        if (try? await probe.listModels()) != nil { ready = true; break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard ready else { throw MockServerError(description: "mock server did not start on port \(port)") }

    try await body(baseURL)
}

private func runChat(
    _ baseURL: String, model: String, messages: [Message] = [Message(role: .user, content: "hello")]
) async throws -> (StreamAccumulator, [ChatDelta]) {
    let client = try ChatClient(baseURL: baseURL, apiKey: "test-key-not-secret")
    var acc = StreamAccumulator()
    var deltas: [ChatDelta] = []
    for try await delta in client.streamChat(messages: messages, options: ChatRequestOptions(model: model)) {
        deltas.append(delta)
        acc.apply(delta)
    }
    acc.finish()
    return (acc, deltas)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private let helloEcho = #"You said: "hello" (0 images received)"#

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
struct MockServerIntegrationTests {
    @Test func listModels() async throws {
        try await withMockServer { base in
            let models = try await ChatClient(baseURL: base + "/", apiKey: nil).listModels()
            for m in ["mock-plain", "mock-reasoning-content", "mock-reasoning", "mock-think-tags",
                      "mock-orphan-think", "mock-error", "mock-stream-error", "mock-slow"] {
                #expect(models.contains(m), "\(m)")
            }
            #expect(models == models.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test func allStreamingModes() async throws {
        try await withMockServer { base in
            let (plain, plainDeltas) = try await runChat(base, model: "mock-plain")
            #expect(plain.content == helloEcho)
            #expect(plain.reasoning == "")
            #expect(plain.finishReason == "stop")
            #expect(plain.usage?.promptTokens == 10)
            #expect(plain.usage?.totalTokens != nil)
            #expect(plainDeltas.count > 2)

            let (rc, _) = try await runChat(base, model: "mock-reasoning-content")
            #expect(rc.reasoning == "Let me think about this request.")
            #expect(rc.content == helloEcho)
            #expect(rc.reasoningDuration != nil)

            let (r, _) = try await runChat(base, model: "mock-reasoning")
            #expect(r.reasoning == "Considering the user's message.")
            #expect(r.content == helloEcho)

            let (tags, _) = try await runChat(base, model: "mock-think-tags")
            #expect(tags.reasoning == "Let me think...")
            #expect(tags.content == helloEcho)
            #expect(tags.reasoningDuration != nil)

            let (orphan, _) = try await runChat(base, model: "mock-orphan-think")
            #expect(orphan.reasoning == "The user wants an echo.")
            #expect(orphan.content == helloEcho)
        }
    }

    @Test func attachmentsReachServer() async throws {
        try await withMockServer { base in
            let png = encodeImage(makeImage(width: 8, height: 8, alpha: true), type: .png)
            let image = try AttachmentLoader.image(data: png, filename: "dot.png")
            let msg = Message(role: .user, content: "look", attachments: [
                image, image,
                Attachment(kind: .text, filename: "a.txt", mimeType: "text/plain", text: "FILEBODY"),
            ])
            let history = [Message(role: .user, content: "earlier"), Message(role: .assistant, content: "ok"), msg]
            let (acc, _) = try await runChat(base, model: "mock-plain", messages: history)
            #expect(acc.content.hasPrefix(#"You said: "look"#))
            #expect(acc.content.contains("<file name=\"a.txt\">\nFILEBODY\n</file>"))
            #expect(acc.content.hasSuffix("(2 images received)"))
        }
    }

    @Test func httpErrorMode() async throws {
        try await withMockServer { base in
            do {
                _ = try await runChat(base, model: "mock-error")
                Issue.record("expected an HTTP error")
            } catch let ParleyError.http(status, body) {
                #expect(status == 400)
                #expect(body.contains("mock bad request"))
            }
        }
    }

    @Test func streamLevelError() async throws {
        try await withMockServer { base in
            await #expect(throws: ParleyError.api("mock stream error")) {
                _ = try await runChat(base, model: "mock-stream-error")
            }
        }
    }

    // Regression: these 200 streams carried an error the client silently dropped.
    @Test func errorsInsideSuccessfulStreamThrow() async throws {
        try await withMockServer { base in
            await #expect(throws: ParleyError.api("boom")) {
                _ = try await runChat(base, model: "mock-sse-error-field")
            }
            await #expect(throws: ParleyError.api("context length exceeded")) {
                _ = try await runChat(base, model: "mock-sse-error-event")
            }
            await #expect(throws: ParleyError.api("bare failure")) {
                _ = try await runChat(base, model: "mock-bare-error")
            }
            let (empty, _) = try await runChat(base, model: "mock-empty")
            #expect(empty.content.isEmpty && empty.reasoning.isEmpty)
        }
    }

    // Regression: URLSession followed 307/308 and replayed the whole conversation to the
    // Location host. Redirects must be refused and surface as an HTTP error.
    @Test func redirectsAreNotFollowed() async throws {
        let listener = try NonBlockingListener()
        defer { listener.close() }
        try await withMockServer { base in
            let root = base.replacingOccurrences(of: "/v1", with: "")
            let redirectBase = "\(root)/redirect-to-\(listener.port)/v1"
            let client = try ChatClient(baseURL: redirectBase, apiKey: "test-key-not-secret")

            let chat = Task {
                for try await _ in client.streamChat(
                    messages: [Message(role: .user, content: "PRIVATE CONVERSATION")],
                    options: ChatRequestOptions(model: "mock-plain")
                ) {}
            }
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                chat.cancel()
            }
            let result = await chat.result
            watchdog.cancel()
            switch result {
            case .success:
                Issue.record("expected the redirect to be refused")
            case .failure(let error):
                guard case ParleyError.http(let status, _)? = error as? ParleyError else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(status == 307)
            }

            let models = Task { try await client.listModels() }
            let modelsWatchdog = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                models.cancel()
            }
            let modelsResult = await models.result
            modelsWatchdog.cancel()
            if case .failure(let error) = modelsResult, case ParleyError.http(let status, _)? = error as? ParleyError {
                #expect(status == 307)
            } else {
                Issue.record("expected listModels to fail with HTTP 307, got \(modelsResult)")
            }
            #expect(listener.acceptedConnections() == 0, "the redirect target was contacted")
        }
    }

    @Test func cancellationStopsPromptly() async throws {
        try await withMockServer { base in
            let client = try ChatClient(baseURL: base, apiKey: nil)
            let received = Counter()
            let stream = client.streamChat(messages: [Message(role: .user, content: "slow")], options: ChatRequestOptions(model: "mock-slow"))
            let consumer = Task {
                for try await delta in stream where delta.content != nil {
                    received.increment()
                }
            }

            let deadline = Date().addingTimeInterval(10)
            while received.value < 3, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(received.value >= 3)

            let cancelledAt = Date()
            consumer.cancel()
            _ = await consumer.result
            let elapsed = Date().timeIntervalSince(cancelledAt)
            #expect(elapsed < 1.0, "stream took \(elapsed)s to end after cancel")
            let countAtEnd = received.value
            #expect(countAtEnd < 20)

            // Nothing keeps arriving after the stream has ended.
            try await Task.sleep(nanoseconds: 500_000_000)
            #expect(received.value == countAtEnd)
        }
    }

    @Test func breakingOutOfLoopEndsRequest() async throws {
        try await withMockServer { base in
            let client = try ChatClient(baseURL: base, apiKey: nil)
            let started = Date()
            var n = 0
            for try await delta in client.streamChat(messages: [Message(role: .user, content: "x")], options: ChatRequestOptions(model: "mock-slow")) where delta.content != nil {
                n += 1
                if n == 2 { break }
            }
            #expect(n == 2)
            #expect(Date().timeIntervalSince(started) < 5)
        }
    }

    @Test func streamOutlivesDroppedClient() async throws {
        try await withMockServer { base in
            // No reference to the client is kept; the stream must still complete.
            let stream = try ChatClient(baseURL: base, apiKey: nil)
                .streamChat(messages: [Message(role: .user, content: "hello")], options: ChatRequestOptions(model: "mock-plain"))
            var acc = StreamAccumulator()
            for try await delta in stream { acc.apply(delta) }
            acc.finish()
            #expect(acc.content == helloEcho)
        }
    }

    @Test func connectionRefusedThrows() async throws {
        let port = try freeLocalPort()
        let client = try ChatClient(baseURL: "http://127.0.0.1:\(port)/v1", apiKey: nil)
        await #expect(throws: (any Error).self) {
            for try await _ in client.streamChat(messages: [Message(role: .user, content: "x")], options: ChatRequestOptions(model: "m")) {}
        }
    }
}
