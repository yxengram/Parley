import Darwin
import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// "Off means identical", at the top of the stack: a fresh AppState with fresh settings, sending
// through toolServices() as the app does, to a socket that keeps the request exactly as it came.
// The strings below were dumped from commit 81e1f71, before any built-in tool code existed. Do not
// regenerate them: they are the proof that with every built-in tool off a conversation sends what
// it always sent, and to no one else. This file uses only API that exists at that commit.
//
// A body with `tools` goes through sorted keys, so its bytes are compared as they are. A body
// without tools has no stable key order between processes (see ChatClient.encodeBody and
// NoToolsGoldens), so those are compared with their keys sorted, plus the exact byte count, which a
// reordering cannot change and any added, removed or changed field does.

private let plainFirstBody = #"{"messages":[{"content":"hello","role":"user"}],"model":"golden-model","stream":true,"stream_options":{"include_usage":true}}"#
private let plainSecondBody = #"{"messages":[{"content":"hello","role":"user"},{"content":"golden reply","role":"assistant"},{"content":"and again","role":"user"}],"model":"golden-model","stream":true,"stream_options":{"include_usage":true}}"#
private let withServerBody = #"{"messages":[{"content":"hello","role":"user"}],"model":"golden-model","stream":true,"stream_options":{"include_usage":true},"tools":[{"function":{"description":"Adds two numbers.","name":"mock__add","parameters":{"type":"object"}},"type":"function"},{"function":{"description":"Echoes the text back.","name":"mock__echo","parameters":{"type":"object"}},"type":"function"}]}"#
/// Every header of the chat request but Host (the port), User-Agent (the OS build), Accept-Language
/// (the system's languages) and Content-Length (the byte counts below).
private let chatHeaders = [
    "Accept-Encoding: gzip, deflate", "Accept: text/event-stream", "Connection: keep-alive", "Content-Type: application/json",
]
private let chatLine = "POST /v1/chat/completions HTTP/1.1"
/// All a send contacts with a real server listed: the probes, then the chat request.
private let withServerLines: Set<String> = [
    "GET /v1/models HTTP/1.1", "GET /api/v1/models HTTP/1.1", "GET /api/v0/models HTTP/1.1", "GET /health HTTP/1.1",
    "GET /props HTTP/1.1", "GET /props?model=golden-model HTTP/1.1", "GET /api/ps HTTP/1.1", chatLine,
]
/// Long enough for a probe or anything else started by the send to reach the socket.
private let settle: UInt64 = 500_000_000

/// One HTTP/1.1 listener on 127.0.0.1 that records requests byte for byte and answers every chat
/// request with one short stream. tools/mock_server.py parses what it receives, so it cannot show
/// the bytes.
private final class WireRecorder: @unchecked Sendable {
    struct Request {
        var line: String
        var headers: [String]
        var body: Data
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let listener: Int32
    let port: Int

    init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = listener
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        guard bound, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: addr.sin_port))
        DispatchQueue.global().async { [self] in acceptLoop() }
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var requests: [Request] { lock.withLock { recorded } }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(buffer, count: count)
        }
        let end = data.range(of: separator)!
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let length = lines.lazy.compactMap { line -> Int? in
            guard line.lowercased().hasPrefix("content-length:") else { return nil }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        while data.count - end.upperBound < length {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(buffer, count: count)
        }
        let request = Request(line: lines[0], headers: Array(lines.dropFirst()), body: Data(data[end.upperBound...]))
        lock.withLock { recorded.append(request) }
        let reply = Self.answer(to: request)
        reply.withUnsafeBytes { _ = write(client, $0.baseAddress, reply.count) }
    }

    private static func answer(to request: Request) -> Data {
        func http(_ status: String, _ type: String, _ body: String) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        }
        if request.line.hasPrefix("POST /v1/chat/completions") {
            return http("200 OK", "text/event-stream", """
            data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"golden reply"}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]


            """)
        }
        if request.line.hasPrefix("GET /v1/models") {
            return http("200 OK", "application/json", #"{"object":"list","data":[{"id":"golden-model","object":"model"}]}"#)
        }
        return http("404 Not Found", "application/json", #"{"error":"not found"}"#)
    }
}

private func sortedKeys(_ body: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: body)
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func chatRequests(_ wire: WireRecorder) -> [WireRecorder.Request] {
    wire.requests.filter { $0.line.hasPrefix("POST") }
}

private func comparableHeaders(_ request: WireRecorder.Request) -> [String] {
    request.headers.filter {
        let name = $0.lowercased()
        return !["host:", "user-agent:", "accept-language:", "content-length:"].contains { name.hasPrefix($0) }
    }.sorted()
}

/// A fresh app on this socket, with a host that records whatever is asked of it.
@MainActor
private func withWire(_ body: (WireRecorder, Fixture, FakeToolHost) async throws -> Void) async throws {
    let wire = try WireRecorder()
    defer { wire.stop() }
    StreamOptionsSupport.forget(baseURL: URL(string: wire.baseURL)!)
    let host = FakeToolHost()
    let fixture = try Fixture(baseURL: wire.baseURL, defaultModel: "golden-model", mcp: host)
    defer { fixture.cleanup() }
    try await body(wire, fixture, host)
}

@Suite(.serialized)
@MainActor
struct BuiltInOffGoldenTests {
    @Test func aPlainChatSendsTheBytesItAlwaysSent() async throws {
        try await withWire { wire, fx, host in
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            try await fx.send("and again", in: session)
            #expect(session.conversation.messages.last?.content == "golden reply")
            try await Task.sleep(nanoseconds: settle)

            // Two chat requests and nothing else: no probe, no connection to anyone.
            #expect(wire.requests.map(\.line) == [chatLine, chatLine])
            let first = try #require(wire.requests.first)
            let second = try #require(wire.requests.last)
            #expect(comparableHeaders(first) == chatHeaders)
            let firstBody = try sortedKeys(first.body), secondBody = try sortedKeys(second.body)
            #expect(firstBody == plainFirstBody)
            #expect(first.body.count == plainFirstBody.utf8.count)
            #expect(secondBody == plainSecondBody)
            #expect(second.body.count == plainSecondBody.utf8.count)
            #expect(host.catalogCount == 0)
            #expect(host.calls.isEmpty)
        }
    }

    /// ReAct is a setting, not a tool: with nothing to offer there is no block in the system message.
    @Test func reactModeWithoutAServerSendsTheSameBytes() async throws {
        try await withWire { wire, fx, host in
            let session = try await fx.create()
            session.conversation.settings.toolMode = ConversationSettings.toolModeReAct
            try await fx.send("hello", in: session)
            try await Task.sleep(nanoseconds: settle)

            #expect(wire.requests.map(\.line) == [chatLine])
            let chat = try #require(wire.requests.first)
            let body = try sortedKeys(chat.body)
            #expect(body == plainFirstBody)
            #expect(chat.body.count == plainFirstBody.utf8.count)
            #expect(host.catalogCount == 0)
        }
    }

    @Test func aRealServerSendsExactlyItsOwnTools() async throws {
        try await withWire { wire, fx, host in
            let config = MCPServerConfig(name: "Mock", command: "/usr/bin/true", useInNewChats: true)
            _ = try fx.state.saveServer(config, secrets: MCPServerSecrets(args: ["--fake"]))
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            try await Task.sleep(nanoseconds: settle)

            let chats = wire.requests.filter { $0.line == chatLine }
            #expect(chats.count == 1)
            let chat = try #require(chats.first)
            #expect(String(decoding: chat.body, as: UTF8.self) == withServerBody)
            #expect(Set(wire.requests.map(\.line)) == withServerLines)
            #expect(host.catalogCount == 1)
        }
    }
}
