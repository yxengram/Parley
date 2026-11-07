import Darwin
import Foundation
import Testing
@testable import ParleyCore

// Shared by the MCP suites. Everything talks to tools/mock_mcp_server.py on stdio or on 127.0.0.1,
// with fake values, an in-memory secret store and a PATH resolver that never runs the real shell.

let mcpPython = "/usr/bin/python3"
let mcpPythonAvailable = FileManager.default.isExecutableFile(atPath: mcpPython)
private let repositoryRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let mcpMockScript = repositoryRoot.appendingPathComponent("tools/mock_mcp_server.py")

/// A folder that goes away with the test.
final class MCPScratch: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("parley-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// What a stdio mock logged: every message it received, as dictionaries.
func mcpLog(_ path: String) -> [[String: Any]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

func mcpReceived(_ path: String) -> [[String: Any]] {
    mcpLog(path).compactMap { $0["received"] as? [String: Any] }
}

func mcpMethods(_ path: String) -> [String] {
    mcpReceived(path).compactMap { $0["method"] as? String }
}

func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// A resolver for tests: a shell that prints nothing, a launchd-like PATH, an empty home.
func mcpTestResolver() -> ShellPATHResolver {
    ShellPATHResolver(launchPATH: "/usr/bin:/bin", shell: "/usr/bin/true", home: NSTemporaryDirectory(), timeout: 2)
}

/// One stdio mock server, its manager and a place for its files.
final class MCPStdioHarness: @unchecked Sendable {
    let scratch: MCPScratch
    let store = InMemoryMCPSecretStore()
    let manager: MCPConnectionManager
    var config: MCPServerConfig
    var logPath: String { scratch.path("log.jsonl") }
    var pidPath: String { scratch.path("pid") }

    init(era: String = "legacy", behaviors: [String] = [], version: String? = nil, name: String = "Mock",
         grace: TimeInterval = 0.3, startupTimeout: Double = 15, env: [String: String] = [:]) throws {
        scratch = try MCPScratch()
        manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "test", stopGrace: grace)
        var args = ["-I", mcpMockScript.path, "--transport", "stdio", "--era", era,
                    "--log-file", scratch.path("log.jsonl"), "--pid-file", scratch.path("pid"), "--max-seconds", "60"]
        if !behaviors.isEmpty { args += ["--behaviors", behaviors.joined(separator: ",")] }
        if let version { args += ["--version", version] }
        config = MCPServerConfig(name: name, command: mcpPython, envNames: env.keys.sorted(), startupTimeout: startupTimeout)
        let secrets = MCPServerSecrets(args: args, env: env)
        let prints = MCPServerConfig.fingerprints(config: config, secrets: secrets)
        config.connectionFingerprint = prints.connection
        config.identityFingerprint = prints.identity
        try store.setSecrets(secrets, for: config.id)
    }

    var pid: pid_t? {
        (try? String(contentsOfFile: pidPath, encoding: .utf8)).flatMap { pid_t($0) }
    }

    func catalog() async -> MCPToolCatalog {
        await manager.catalog(for: [config])
    }

    func binding(_ tool: String, in catalog: MCPToolCatalog) throws -> MCPToolBinding {
        try #require(catalog.bindings.first { $0.tool.name == tool }, "no tool \(tool)")
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:], timeout: TimeInterval = 10, maxCharacters: Int = 32_000) async throws -> ToolCallResult {
        let binding = try await binding(tool, in: catalog())
        return await manager.call(binding, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters)
    }

    /// Stops everything, however the test ended.
    func finish() {
        manager.shutdownSync(grace: 0.2)
    }
}

final class MCPFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// True once nothing with this pid is left.
func processIsGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) != 0 && errno == ESRCH
}

// MARK: - HTTP mock

func mcpFreePort() throws -> Int {
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

struct MCPMockFailed: Error, CustomStringConvertible { let description: String }

/// One HTTP mock server and a manager pointed at it.
final class MCPHTTPHarness: @unchecked Sendable {
    let process = Process()
    let port: Int
    let store = InMemoryMCPSecretStore()
    let oauthStore = InMemoryMCPOAuthStore()
    let manager: MCPConnectionManager
    var config: MCPServerConfig
    var url: String { "http://127.0.0.1:\(port)/mcp" }
    private let exited = DispatchSemaphore(value: 0)

    init(era: String = "legacy", behaviors: [String] = [], headers: [String: String] = [:], version: String? = nil,
         environment: [String: String] = [:]) async throws {
        port = try mcpFreePort()
        var args = ["-I", "-u", mcpMockScript.path, "--transport", "http", "--port", String(port), "--era", era, "--max-seconds", "60"]
        if !behaviors.isEmpty { args += ["--behaviors", behaviors.joined(separator: ",")] }
        if let version { args += ["--version", version] }
        process.executableURL = URL(fileURLWithPath: mcpPython)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let semaphore = exited
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()

        manager = MCPConnectionManager(secrets: store, oauthStore: oauthStore, pathResolver: mcpTestResolver(), clientVersion: "test", stopGrace: 0.3)
        config = MCPServerConfig(name: "Remote", kind: MCPServerConfig.kindHTTP, urlHost: "127.0.0.1",
                                 headerNames: headers.keys.sorted(), startupTimeout: 10)
        let secrets = MCPServerSecrets(url: "http://127.0.0.1:\(port)/mcp", headers: headers)
        let prints = MCPServerConfig.fingerprints(config: config, secrets: secrets)
        config.connectionFingerprint = prints.connection
        config.identityFingerprint = prints.identity
        try store.setSecrets(secrets, for: config.id)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await log()) != nil { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw MCPMockFailed(description: "the HTTP mock did not start")
    }

    /// Bare URLSession, outside anything under test.
    func log() async throws -> [[String: Any]] {
        let url = URL(string: "http://127.0.0.1:\(port)/mock/log")!
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    func expireSessions() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mock/expire-sessions")!)
        request.httpMethod = "POST"
        _ = try await URLSession(configuration: .ephemeral).data(for: request)
    }

    func refuseInitialize() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mock/refuse-initialize")!)
        request.httpMethod = "POST"
        _ = try await URLSession(configuration: .ephemeral).data(for: request)
    }

    /// Requests in the order they arrived: (HTTP method, JSON-RPC method, headers lower-cased, body).
    func requests() async throws -> [(http: String, method: String?, headers: [String: String], body: [String: Any])] {
        try await log().compactMap { entry in
            guard let http = entry["http"] as? String else { return nil }
            let body = entry["body"] as? [String: Any] ?? [:]
            return (http, body["method"] as? String, entry["headers"] as? [String: String] ?? [:], body)
        }
    }

    func catalog() async -> MCPToolCatalog {
        await manager.catalog(for: [config])
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:], timeout: TimeInterval = 10) async throws -> ToolCallResult {
        let list = await catalog()
        let binding = try #require(list.bindings.first { $0.tool.name == tool }, "no tool \(tool): \(list.unavailable)")
        return await manager.call(binding, arguments: arguments, timeout: timeout, maxCharacters: 32_000)
    }

    func finish() {
        manager.shutdownSync(grace: 0.2)
        if process.isRunning { process.terminate() }
        _ = exited.wait(timeout: .now() + 5)
    }
}
