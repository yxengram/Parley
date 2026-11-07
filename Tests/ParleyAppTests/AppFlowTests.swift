import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Headless app-layer flow tests: they drive the real AppState / ConversationSession against
// tools/mock_server.py and assert on what ends up on disk.
//
// Isolation: every test gets its own temp directory, a UserDefaults suite stored inside it, and a
// mock provider with a random id (no Keychain item exists for it, so the API key is nil). Nothing
// touches ~/Library/Application Support/Parley, UserDefaults.standard or real Keychain items.

@MainActor
@Test func appStateConstructs() throws {
    let root = try makeTempRoot()
    let suiteName = defaultsSuiteName(in: root)
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { removeDefaultsSuite(suiteName, defaults, root: root) }
    let state = AppState(settings: AppSettings(defaults: defaults))
    #expect(state.entries.isEmpty)
}

// MARK: - Mock server

let python3Path = "/usr/bin/python3"

let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()   // ParleyAppTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("tools/mock_server.py")

struct FlowTestError: Error, CustomStringConvertible {
    let description: String
}

func freeLocalPort() throws -> Int {
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

/// Set from the process's termination handler (a background queue).
final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    func set() { lock.lock(); exited = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return exited }
}

/// A running mock server.
struct MockServer {
    let process: Process
    let exited: ExitFlag
    let baseURL: String

    /// Terminates the server and waits (without blocking or spinning a run loop) for it to exit.
    /// `Process.waitUntilExit()` is avoided: it runs the current run loop, which on the main
    /// thread would execute other main-actor work re-entrantly.
    func stop() async {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while !exited.value && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Starts the mock server on a free port. Retries with a new port if the server exits before
/// it answers (another suite may have grabbed the same free port in the meantime).
@MainActor
func startMockServer(flavor: String? = nil, environment: [String: String] = [:]) async throws -> MockServer {
    guard FileManager.default.fileExists(atPath: mockServerScript.path) else {
        throw FlowTestError(description: "mock server not found at \(mockServerScript.path)")
    }
    for _ in 0..<5 {
        let port = try freeLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3Path)
        process.arguments = ["-I", "-u", mockServerScript.path, String(port)] + (flavor.map { [$0] } ?? [])
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = ExitFlag()
        process.terminationHandler = { _ in exited.set() }
        try process.run()

        let server = MockServer(process: process, exited: exited, baseURL: "http://127.0.0.1:\(port)/v1")
        // A port can be handed out again in this process: what an earlier server on it refused is not this one's.
        StreamOptionsSupport.forget(baseURL: URL(string: server.baseURL)!)
        let probe = try ChatClient(baseURL: server.baseURL, apiKey: nil)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !exited.value {
            if (try? await probe.listModels()) != nil { return server }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await server.stop()
    }
    throw FlowTestError(description: "mock server did not start")
}

// MARK: - Fixture

func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ParleyAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A unique suite name that is an absolute path inside the test's temp directory, so the suite's
/// plist lives there (CFPreferences treats an absolute path as the plist location) and goes away
/// with it. A plain reverse-DNS suite name leaves an empty plist in ~/Library/Preferences, because
/// cfprefsd writes the emptied domain back after the test has deleted the file.
func defaultsSuiteName(in root: URL) -> String {
    root.appendingPathComponent("defaults").path
}

func removeDefaultsSuite(_ name: String, _ suite: UserDefaults, root: URL) {
    suite.removePersistentDomain(forName: name)
    try? FileManager.default.removeItem(at: root)
}

/// One isolated app: its own defaults suite, temp directories and a provider pointing at the mock.
@MainActor
final class Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let root: URL
    let defaultDir: URL
    let settings: AppSettings
    let state: AppState
    let provider: Provider
    /// Stands in for the Keychain: nothing here reads or writes an MCP item.
    let mcpSecrets = InMemoryMCPSecretStore()

    /// `mcp` nil gets a real manager that cannot run a real login shell.
    init(baseURL: String, defaultModel: String, mcp: MCPToolHost? = nil) throws {
        root = try makeTempRoot()
        suiteName = defaultsSuiteName(in: root)
        defaultDir = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)

        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FlowTestError(description: "could not create defaults suite")
        }
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)
        // First launch seeds an "LM Studio (local)" provider; replace it with the mock.
        provider = Provider(name: "Mock", baseURL: baseURL, defaultModel: defaultModel)
        settings.providers = [provider]
        settings.defaultProviderID = provider.id
        settings.defaultDirectoryPath = defaultDir.path
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin:/bin", shell: "/usr/bin/true", home: NSTemporaryDirectory(), timeout: 2)
        let host = mcp ?? MCPConnectionManager(secrets: mcpSecrets, pathResolver: resolver, clientVersion: "test", stopGrace: 0.3)
        state = AppState(settings: settings, mcp: host, mcpSecrets: mcpSecrets)
    }

    /// A directory other than the default one (created lazily by the app on first write).
    func customDirectory(_ name: String = "Custom") -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    func cleanup() {
        for session in state.sessions.values {
            session.close(saving: false)
        }
        state.mcp.shutdownSync(grace: 0.2)
        // A queued write landing after removeItem would recreate the directory.
        ConversationWriter.flush()
        removeDefaultsSuite(suiteName, defaults, root: root)
    }

    /// Creates a conversation through AppState (as the New Chat sheet does) and returns its session.
    func create(title: String = "", in directory: URL? = nil, password: String? = nil) async throws -> ConversationSession {
        try await state.createConversation(title: title, directory: directory ?? defaultDir, password: password)
        let id = try #require(state.selection)
        return try #require(state.session(for: id))
    }

    /// What the composer does on Send.
    func send(_ text: String, in session: ConversationSession) async throws {
        session.draftText = ""
        session.draftAttachments = []
        session.send(text: text, attachments: [], settings: settings)
        try await waitForReply(session)
    }

    func waitForReply(_ session: ConversationSession) async throws {
        try #require(await waitUntil { !session.isStreaming }, "reply did not finish in time")
    }
}

@MainActor
func withFixture(
    model: String = "mock-plain",
    flavor: String? = nil,
    environment: [String: String] = [:],
    mcp: MCPToolHost? = nil,
    _ body: (Fixture) async throws -> Void
) async throws {
    let server = try await startMockServer(flavor: flavor, environment: environment)
    do {
        let fixture = try Fixture(baseURL: server.baseURL, defaultModel: model, mcp: mcp)
        defer { fixture.cleanup() }
        try await body(fixture)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

// MARK: - Disk helpers

/// Waits for every queued background save, then reads the file.
func readFile(_ url: URL) throws -> Data {
    ConversationWriter.flush()
    return try Data(contentsOf: url)
}

func readPlain(_ url: URL) throws -> Conversation {
    try ConversationFile.decodePlain(readFile(url))
}

func contains(_ data: Data, _ text: String) -> Bool {
    data.range(of: Data(text.utf8)) != nil
}

/// Every entry in the directory, hidden files included.
func listing(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

func echo(_ text: String) -> String {
    #"You said: "\#(text)" (0 images received)"#
}

/// Field-wise equality. Dates are written as ISO 8601 without fractional seconds, so they only
/// round-trip to within a second.
func expectSameMessages(_ disk: [Message], _ memory: [Message], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(disk.count == memory.count, sourceLocation: sourceLocation)
    for (d, m) in zip(disk, memory) {
        #expect(d.id == m.id, sourceLocation: sourceLocation)
        #expect(d.role == m.role, sourceLocation: sourceLocation)
        #expect(d.content == m.content, sourceLocation: sourceLocation)
        #expect(d.reasoning == m.reasoning, sourceLocation: sourceLocation)
        #expect(d.reasoningDuration == m.reasoningDuration, sourceLocation: sourceLocation)
        #expect(d.isComplete == m.isComplete, sourceLocation: sourceLocation)
        #expect(d.error == m.error, sourceLocation: sourceLocation)
        #expect(d.model == m.model, sourceLocation: sourceLocation)
        #expect(d.attachments == m.attachments, sourceLocation: sourceLocation)
        #expect(abs(d.createdAt.timeIntervalSince(m.createdAt)) < 1, sourceLocation: sourceLocation)
    }
}

// MARK: - Flows

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
@MainActor
struct AppFlowTests {
    // 1. Plain conversation in a custom directory, reasoning via inline <think> tags.
    @Test func plainConversationWithThinkTags() async throws {
        try await withFixture(model: "mock-think-tags") { fx in
            let dir = fx.customDirectory()
            let session = try await fx.create(in: dir)
            #expect(session.conversation.title == ConversationSession.defaultTitle)
            #expect(session.conversation.settings.model == "mock-think-tags")
            #expect(session.conversation.settings.providerID == fx.provider.id)

            try await fx.send("hello", in: session)

            let messages = session.conversation.messages
            try #require(messages.count == 2)
            #expect(messages[0].role == .user)
            #expect(messages[0].content == "hello")
            let reply = messages[1]
            #expect(reply.role == .assistant)
            #expect(reply.error == nil)
            #expect(reply.content == echo("hello"))
            #expect(!reply.content.contains("<think"))
            #expect(!reply.content.contains("think>"))
            #expect(reply.reasoning == "Let me think...")
            #expect(reply.isComplete)
            let duration = try #require(reply.reasoningDuration)
            #expect(duration >= 0)
            #expect(reply.model == "mock-think-tags")
            #expect(session.conversation.title == "hello")

            // On disk: exactly <UUID>.json in the chosen directory, nothing in the default one.
            let fileName = ConversationFile.fileName(for: session.id)
            #expect(fileName == "\(session.id.uuidString).json")
            #expect(session.fileURL == dir.appendingPathComponent(fileName))
            ConversationWriter.flush()
            #expect(listing(dir) == [fileName])
            #expect(listing(fx.defaultDir).isEmpty)

            let data = try readFile(session.fileURL)
            let header = try ConversationFile.peek(data)
            #expect(header.id == session.id)
            #expect(!header.isEncrypted)
            #expect(header.title == "hello")
            #expect(header.messageCount == 2)
            let decoded = try ConversationFile.decodePlain(data)
            #expect(decoded.id == session.id)
            #expect(decoded.title == "hello")
            expectSameMessages(decoded.messages, messages)

            // The file outside the default directory is remembered (path only) and listed.
            let path = AppSettingsPaths.normalized(session.fileURL)
            #expect(fx.settings.extraConversationPaths == [path])
            let entry = try #require(fx.state.entry(id: session.id))
            #expect(entry.title == "hello")
            #expect(!entry.isEncrypted)
            #expect(fx.state.selection == session.id)
        }
    }

    // 2. Rollback.
    @Test func rollbackTruncatesFile() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("first", in: session)
            try await fx.send("second", in: session)
            #expect(session.conversation.messages.map(\.content) == ["first", echo("first"), "second", echo("second")])
            #expect(try readPlain(session.fileURL).messages.count == 4)

            session.rollback(toMessageAt: 1)

            #expect(session.conversation.messages.count == 2)
            let onDisk = try readPlain(session.fileURL)
            #expect(onDisk.messages.count == 2)
            #expect(onDisk.messages.map(\.content) == ["first", echo("first")])
            expectSameMessages(onDisk.messages, session.conversation.messages)
        }
    }

    // 3. Edit & resend, then regenerate.
    @Test func editAndResendThenRegenerate() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("first", in: session)
            try await fx.send("second", in: session)

            // Edit & resend the second user message: it goes back into the composer.
            session.editAndResend(messageAt: 2)
            #expect(session.draftText == "second")
            #expect(session.conversation.messages.count == 2)
            #expect(try readPlain(session.fileURL).messages.count == 2)

            try await fx.send(session.draftText + " (edited)", in: session)
            var messages = session.conversation.messages
            #expect(messages.map(\.content) == ["first", echo("first"), "second (edited)", echo("second (edited)")])
            #expect(messages.allSatisfy { $0.error == nil })
            #expect(messages[3].isComplete)
            expectSameMessages(try readPlain(session.fileURL).messages, messages)

            // Regenerate the last reply: same count, new message, same echo.
            let oldReplyID = messages[3].id
            session.regenerate(messageAt: 3, settings: fx.settings)
            try await fx.waitForReply(session)
            messages = session.conversation.messages
            #expect(messages.count == 4)
            #expect(messages[3].id != oldReplyID)
            #expect(messages[3].role == .assistant)
            #expect(messages[3].content == echo("second (edited)"))
            #expect(messages[3].isComplete)
            let onDisk = try readPlain(session.fileURL)
            expectSameMessages(onDisk.messages, messages)

            // Regenerating the first reply drops everything after it.
            session.regenerate(messageAt: 1, settings: fx.settings)
            try await fx.waitForReply(session)
            #expect(session.conversation.messages.map(\.content) == ["first", echo("first")])
            #expect(try readPlain(session.fileURL).messages.count == 2)

            // Neither applies to the wrong role.
            session.editAndResend(messageAt: 1)
            session.regenerate(messageAt: 0, settings: fx.settings)
            #expect(session.conversation.messages.count == 2)
            #expect(!session.isStreaming)
        }
    }

    // 3b. Staged edit (what the UI uses): nothing changes until the edit is sent.
    @Test func stagedEditKeepsHistoryUntilSent() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("first", in: session)
            try await fx.send("second", in: session)

            session.beginEdit(messageAt: 2)
            #expect(session.draftText == "second")
            #expect(session.pendingEditIndex == 2)
            #expect(session.conversation.messages.count == 4)
            #expect(try readPlain(session.fileURL).messages.count == 4)

            // Cancelling leaves the conversation as it was.
            session.cancelEdit()
            #expect(session.pendingEditMessageID == nil)
            #expect(session.draftText.isEmpty)

            // A draft typed before the edit comes back on cancel.
            session.draftText = "half-typed"
            session.beginEdit(messageAt: 2)
            #expect(session.draftText == "second")
            session.cancelEdit()
            #expect(session.draftText == "half-typed")
            session.draftText = ""
            #expect(session.conversation.messages.count == 4)

            // Sending the edit replaces the message and everything after it.
            session.beginEdit(messageAt: 2)
            try await fx.send("second (edited)", in: session)
            #expect(session.pendingEditMessageID == nil)
            #expect(session.conversation.messages.map(\.content) == ["first", echo("first"), "second (edited)", echo("second (edited)")])
            expectSameMessages(try readPlain(session.fileURL).messages, session.conversation.messages)
        }
    }

    // 4. Encrypted conversation: nothing readable on disk; lock / unlock through AppState.
    @Test func encryptedConversationLockUnlock() async throws {
        try await withFixture { fx in
            let title = "Secret Title Zebra"
            let secret = "classified-marker-42"
            let password = "correct horse battery"
            let session = try await fx.create(title: title, password: password)
            #expect(session.isEncrypted)
            try await fx.send(secret, in: session)
            #expect(session.conversation.messages.map(\.content) == [secret, echo(secret)])
            #expect(session.conversation.title == title)

            let raw = try readFile(session.fileURL)
            #expect(!contains(raw, title))
            #expect(!contains(raw, secret))
            #expect(!contains(raw, "You said"))
            let header = try ConversationFile.peek(raw)
            #expect(header.isEncrypted)
            #expect(header.title == nil)
            #expect(header.messageCount == nil)
            let (decoded, _) = try ConversationFile.decodeEncrypted(raw, password: password)
            #expect(decoded.title == title)
            expectSameMessages(decoded.messages, session.conversation.messages)

            // Lock drops the session and any link waiting for an answer; the library entry keeps no title.
            let id = session.id
            #expect(fx.state.requestOpen(URL(string: "https://example.com/?q=secret")!))
            fx.state.lock(id)
            #expect(fx.state.notice == nil)
            #expect(fx.state.session(for: id) == nil)
            #expect(fx.state.pendingLink == nil)
            let entry = try #require(fx.state.entry(id: id))
            #expect(entry.isEncrypted)
            #expect(entry.title == nil)
            #expect(fx.state.displayTitle(for: entry) == nil)

            // Wrong password.
            await #expect(throws: ParleyError.wrongPassword) {
                try await fx.state.unlock(entry, password: "wrong password")
            }
            #expect(fx.state.session(for: id) == nil)

            // Correct password.
            try await fx.state.unlock(entry, password: password)
            let reopened = try #require(fx.state.session(for: id))
            #expect(reopened.isEncrypted)
            #expect(reopened.conversation.title == title)
            #expect(fx.state.displayTitle(for: entry) == title)
            expectSameMessages(reopened.conversation.messages, decoded.messages)

            // Still usable after unlocking, and the file stays encrypted.
            try await fx.send("again", in: reopened)
            #expect(reopened.conversation.messages.count == 4)
            let raw2 = try readFile(reopened.fileURL)
            #expect(!contains(raw2, "again"))
            #expect(!contains(raw2, title))
            let (decoded2, _) = try ConversationFile.decodeEncrypted(raw2, password: password)
            expectSameMessages(decoded2.messages, reopened.conversation.messages)

            fx.state.lock(id)
            #expect(fx.state.session(for: id) == nil)
            #expect(fx.state.displayTitle(for: entry) == nil)
        }
    }

    // 5. Fork an encrypted conversation.
    @Test func forkEncryptedConversation() async throws {
        try await withFixture { fx in
            let password = "fork password"
            let dir = fx.customDirectory("Forks")
            let session = try await fx.create(title: "Fork Source", in: dir, password: password)
            try await fx.send("one", in: session)
            try await fx.send("two", in: session)
            #expect(session.conversation.messages.count == 4)

            fx.state.fork(session, through: 1)
            #expect(fx.state.notice == nil)
            let forkID = try #require(fx.state.selection)
            #expect(forkID != session.id)
            let fork = try #require(fx.state.session(for: forkID))
            #expect(fork.isEncrypted)
            #expect(fork.fileURL.deletingLastPathComponent() == session.fileURL.deletingLastPathComponent())

            ConversationWriter.flush()
            #expect(listing(dir) == [
                ConversationFile.fileName(for: session.id),
                ConversationFile.fileName(for: forkID),
            ].sorted())

            let raw = try readFile(fork.fileURL)
            #expect(try ConversationFile.peek(raw).isEncrypted)
            #expect(!contains(raw, "Fork Source"))
            #expect(!contains(raw, "one"))
            let (decoded, _) = try ConversationFile.decodeEncrypted(raw, password: password)
            #expect(decoded.id == forkID)
            #expect(decoded.messages.count == 2)
            #expect(decoded.messages.map(\.content) == ["one", echo("one")])
            let origin = try #require(decoded.forkedFrom)
            #expect(origin.conversationID == session.id)
            #expect(origin.messageID == session.conversation.messages[1].id)

            // The source is unchanged.
            let (source, _) = try ConversationFile.decodeEncrypted(try readFile(session.fileURL), password: password)
            #expect(source.messages.count == 4)
            #expect(source.forkedFrom == nil)
        }
    }

    // 6. Encrypt an existing plain conversation, then remove encryption.
    @Test func encryptThenDecryptExisting() async throws {
        try await withFixture { fx in
            let session = try await fx.create(title: "Plain Then Secret")
            try await fx.send("pineapple-marker", in: session)
            let url = session.fileURL

            var raw = try readFile(url)
            #expect(contains(raw, "Plain Then Secret"))
            #expect(contains(raw, "pineapple-marker"))
            #expect(try !ConversationFile.peek(raw).isEncrypted)

            let newlyEncrypted = try await fx.state.setPassword(for: session, password: "pw-1")
            #expect(newlyEncrypted)
            #expect(session.isEncrypted)
            #expect(session.fileURL == url)
            raw = try readFile(url)
            #expect(try ConversationFile.peek(raw).isEncrypted)
            #expect(!contains(raw, "Plain Then Secret"))
            #expect(!contains(raw, "pineapple-marker"))
            var (decoded, _) = try ConversationFile.decodeEncrypted(raw, password: "pw-1")
            expectSameMessages(decoded.messages, session.conversation.messages)
            #expect(fx.state.entry(id: session.id)?.isEncrypted == true)
            #expect(fx.state.entry(id: session.id)?.title == nil)

            // Changing the password re-keys the file.
            #expect(try await fx.state.setPassword(for: session, password: "pw-2") == false)
            raw = try readFile(url)
            #expect(throws: ParleyError.wrongPassword) { try ConversationFile.decodeEncrypted(raw, password: "pw-1") }
            (decoded, _) = try ConversationFile.decodeEncrypted(raw, password: "pw-2")
            #expect(decoded.messages.count == 2)

            // A send while encrypted stays encrypted.
            try await fx.send("kiwi-marker", in: session)
            raw = try readFile(url)
            #expect(!contains(raw, "kiwi-marker"))

            fx.state.removeEncryption(from: session)
            #expect(fx.state.notice == nil)
            #expect(!session.isEncrypted)
            raw = try readFile(url)
            #expect(try !ConversationFile.peek(raw).isEncrypted)
            #expect(contains(raw, "Plain Then Secret"))
            #expect(contains(raw, "kiwi-marker"))
            let plain = try ConversationFile.decodePlain(raw)
            expectSameMessages(plain.messages, session.conversation.messages)
            #expect(plain.messages.count == 4)
            #expect(fx.state.entry(id: session.id)?.isEncrypted == false)
            #expect(fx.state.entry(id: session.id)?.title == "Plain Then Secret")

            // Only the one file, no temp leftovers.
            #expect(listing(fx.defaultDir) == [url.lastPathComponent])
        }
    }

    // 7. Stop mid-stream keeps the partial reply, and nothing changes afterwards.
    @Test func stopMidStream() async throws {
        try await withFixture(model: "mock-slow") { fx in
            let session = try await fx.create()
            session.send(text: "slow please", attachments: [], settings: fx.settings)
            #expect(session.isStreaming)

            // The placeholder is saved as soon as the request starts.
            var inFlight = try readPlain(session.fileURL)
            #expect(inFlight.messages.count == 2)
            #expect(inFlight.messages.last?.isComplete == false)

            // While streaming, the partial reply is also saved periodically (~every 2 s).
            try #require(await waitUntil {
                session.conversation.messages.last?.content.contains("token12") == true
            }, "no streamed tokens arrived")
            #expect(session.isStreaming)
            inFlight = try readPlain(session.fileURL)
            let savedPartial = try #require(inFlight.messages.last)
            #expect(!savedPartial.isComplete)
            #expect(savedPartial.content.contains("token"))

            session.stop()
            #expect(!session.isStreaming)
            let stopped = session.conversation
            let partial = try #require(stopped.messages.last)
            #expect(partial.role == .assistant)
            #expect(!partial.isComplete)
            #expect(partial.error == nil)
            #expect(partial.content.hasPrefix(echo("slow please")))
            #expect(!partial.content.contains("token50"))

            let bytesAtStop = try readFile(session.fileURL)
            let onDisk = try ConversationFile.decodePlain(bytesAtStop)
            #expect(onDisk.messages.count == 2)
            let diskPartial = try #require(onDisk.messages.last)
            #expect(!diskPartial.isComplete)
            #expect(diskPartial.content == partial.content)

            // Several mock-slow intervals later: neither memory nor disk has changed.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            #expect(session.conversation == stopped)
            #expect(!session.isStreaming)
            #expect(try readFile(session.fileURL) == bytesAtStop)
        }
    }

    // Lock while a reply is streaming: the partial reply is saved encrypted and nothing is
    // written after the session is dropped.
    @Test func lockMidStream() async throws {
        try await withFixture(model: "mock-slow") { fx in
            let session = try await fx.create(title: "Locked Mid Stream", password: "pw")
            session.send(text: "slow secret", attachments: [], settings: fx.settings)
            try #require(await waitUntil {
                session.conversation.messages.last?.content.contains("token2") == true
            }, "no streamed tokens arrived")

            fx.state.lock(session.id)
            #expect(fx.state.notice == nil)
            #expect(fx.state.session(for: session.id) == nil)
            #expect(!session.isStreaming)

            let raw = try readFile(session.fileURL)
            #expect(!contains(raw, "slow secret"))
            #expect(!contains(raw, "token"))
            let (decoded, _) = try ConversationFile.decodeEncrypted(raw, password: "pw")
            #expect(decoded.messages.count == 2)
            let partial = try #require(decoded.messages.last)
            #expect(!partial.isComplete)
            #expect(partial.content.hasPrefix(echo("slow secret")))
            #expect(partial.content.contains("token2"))

            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(try readFile(session.fileURL) == raw)
        }
    }

    // 8. HTTP error, then retry after switching the model.
    @Test func httpErrorThenRetryWithAnotherModel() async throws {
        try await withFixture(model: "mock-error") { fx in
            let session = try await fx.create()
            try await fx.send("will fail", in: session)

            var messages = session.conversation.messages
            try #require(messages.count == 2)
            let failed = messages[1]
            let error = try #require(failed.error)
            #expect(error.contains("400"))
            #expect(error.contains("mock bad request"))
            #expect(!failed.isComplete)
            #expect(failed.model == "mock-error")
            var onDisk = try readPlain(session.fileURL)
            #expect(onDisk.messages.count == 2)
            #expect(onDisk.messages[1].error == error)

            // Switch the model as the toolbar does, then Retry (= regenerate).
            session.conversation.settings.model = "mock-plain"
            session.settingsChanged(debounced: false)
            #expect(try readPlain(session.fileURL).settings.model == "mock-plain")
            session.regenerate(messageAt: 1, settings: fx.settings)
            try await fx.waitForReply(session)

            messages = session.conversation.messages
            #expect(messages.count == 2)
            #expect(messages[1].id != failed.id)
            #expect(messages[1].error == nil)
            #expect(messages[1].isComplete)
            #expect(messages[1].model == "mock-plain")
            #expect(messages[1].content == echo("will fail"))
            onDisk = try readPlain(session.fileURL)
            expectSameMessages(onDisk.messages, messages)
        }
    }

    // Relaunch: a fresh AppState over the same settings finds both files and reopens them.
    @Test func relaunchScansLibrary() async throws {
        try await withFixture { fx in
            let plain = try await fx.create(title: "Visible Title", in: fx.customDirectory())
            try await fx.send("plain text", in: plain)
            let secret = try await fx.create(title: "Hidden Title", password: "pw")
            try await fx.send("secret text", in: secret)
            ConversationWriter.flush()

            let relaunched = AppState(settings: fx.settings)
            relaunched.reloadLibrary()
            try #require(await waitUntil { !relaunched.isScanning && relaunched.entries.count == 2 })

            let plainEntry = try #require(relaunched.entry(id: plain.id))
            #expect(!plainEntry.isEncrypted)
            #expect(plainEntry.title == "Visible Title")
            #expect(AppSettingsPaths.normalized(plainEntry.url) == AppSettingsPaths.normalized(plain.fileURL))
            let secretEntry = try #require(relaunched.entry(id: secret.id))
            #expect(secretEntry.isEncrypted)
            #expect(secretEntry.title == nil)
            #expect(relaunched.displayTitle(for: secretEntry) == nil)

            let reopened = try #require(await relaunched.loadPlain(plainEntry))
            expectSameMessages(reopened.conversation.messages, plain.conversation.messages)
            #expect(await relaunched.loadPlain(secretEntry) == nil)
            try await relaunched.unlock(secretEntry, password: "pw")
            let unlocked = try #require(relaunched.session(for: secret.id))
            expectSameMessages(unlocked.conversation.messages, secret.conversation.messages)
            #expect(relaunched.displayTitle(for: secretEntry) == "Hidden Title")

            for s in relaunched.sessions.values { s.close(saving: false) }
        }
    }

    // Speed and context: stats land on the reply (and on disk), the probe fills the cache,
    // a manual value persists, and a reload goes through the mock's LM Studio endpoints.
    @Test func replyStoresGenerationStats() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("speed", in: session)
            let reply = try #require(session.conversation.messages.last)
            let stats = try #require(reply.stats)
            // The mock streams usage (stream_options was sent), so the count is the server's.
            #expect(stats.isEstimated == false)
            #expect(stats.completionTokens == reply.usage?.completionTokens)
            #expect(stats.timeToFirstToken != nil)
            #expect(session.liveGeneration == nil)
            #expect(try readPlain(session.fileURL).messages.last?.stats == stats)
        }
    }

    @Test func liveGenerationWhileStreaming() async throws {
        try await withFixture(model: "mock-slow") { fx in
            let session = try await fx.create()
            session.send(text: "slow", attachments: [], settings: fx.settings)
            #expect(session.liveGeneration != nil)
            try #require(await waitUntil { (session.liveGeneration?.tokensPerSecond ?? 0) > 0 })
            let live = try #require(session.liveGeneration)
            #expect(live.isEstimated)           // usage arrives only at the end
            #expect(live.tokens >= 2)
            // The strip's usage: cached history plus the live count.
            let history = ContextBudget.usage(messages: session.conversation.messages, systemPrompt: "",
                                              inFlightID: session.streamingMessageID)
            #expect(session.contextUsage().tokens == history.tokens + (session.liveGeneration?.tokens ?? 0))
            session.stop()
            #expect(session.liveGeneration == nil)
            // Stopped replies keep what was measured.
            #expect(session.conversation.messages.last?.stats?.tokensPerSecond != nil)
        }
    }

    @Test func contextProbeAndManualValue() async throws {
        try await withFixture { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-plain")
            let info = try #require(fx.state.contextInfo(provider: fx.provider, model: "mock-plain"))
            #expect(info.serverKind == .lmStudio)
            #expect(info.loadedContextLength == 8192)
            #expect(ContextBudget.limit(info: info, manual: 4096)?.source == .server)

            fx.settings.setManualContextLength(24000, providerID: fx.provider.id, model: "mock-notloaded")
            // Stored in the same defaults suite: a relaunch sees it.
            let reread = AppSettings(defaults: fx.defaults)
            #expect(reread.manualContextLength(providerID: fx.provider.id, model: "mock-notloaded") == 24000)
            #expect(reread.manualContextLength(providerID: UUID(), model: "mock-notloaded") == nil)
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-notloaded")
            let idle = fx.state.contextInfo(provider: fx.provider, model: "mock-notloaded")
            #expect(ContextBudget.limit(info: idle, manual: reread.manualContextLength(providerID: fx.provider.id, model: "mock-notloaded"))
                    == ContextLimit(tokens: 24000, source: .manual))
            fx.settings.setManualContextLength(nil, providerID: fx.provider.id, model: "mock-notloaded")
            #expect(AppSettings(defaults: fx.defaults).contextLengthOverrides.isEmpty)
        }
    }

    @Test func reloadModelThroughAppState() async throws {
        try await withFixture { fx in
            // A size learned from an earlier overflow described the old load.
            fx.settings.setLearnedContextLength(4000, providerID: fx.provider.id, model: "mock-plain")
            try await fx.state.reloadModel(provider: fx.provider, model: "mock-plain", contextLength: 12000)
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "mock-plain") == nil)
            let info = try #require(fx.state.contextInfo(provider: fx.provider, model: "mock-plain"))
            #expect(info.loadedContextLength == 12000)
            #expect(info.instanceIDs == ["mock-plain"])
            // A refused reload still refreshes what the server reports.
            await #expect(throws: (any Error).self) {
                try await fx.state.reloadModel(provider: fx.provider, model: "mock-plain", contextLength: 10_000_000)
            }
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-plain")?.loadedContextLength == 12000)
            #expect(!fx.state.isProbingContext(provider: fx.provider, model: "mock-plain"))
            // The failure is kept in AppState (the popover may have been closed meanwhile).
            guard case .failed(let message) = fx.state.reloadState(provider: fx.provider, model: "mock-plain") else {
                Issue.record("no failed reload state")
                return
            }
            #expect(message.hasPrefix("Reload failed"))
            fx.state.clearReloadState(provider: fx.provider, model: "mock-plain")
            #expect(fx.state.reloadState(provider: fx.provider, model: "mock-plain") == nil)
        }
    }

    // A view's .task is cancelled when the user switches conversations mid-probe: the probe
    // belongs to AppState, so its result still lands (the old code cached an empty result here).
    @Test func cancelledCallerDoesNotLoseTheProbe() async throws {
        try await withFixture { fx in
            let cancelled = Task { await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-plain") }
            cancelled.cancel()
            await cancelled.value
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-plain")?.loadedContextLength == 8192)
            #expect(!fx.state.isProbingContext(provider: fx.provider, model: "mock-plain"))

            // A second caller while a probe runs joins it and sees its result.
            async let first: Void = fx.state.refreshContextInfo(provider: fx.provider, model: "mock-notloaded")
            async let second: Void = fx.state.refreshContextInfo(provider: fx.provider, model: "mock-notloaded")
            _ = await (first, second)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-notloaded")?.maxContextLength != nil)
        }
    }

    // Nothing learned (server not running): nothing cached, and the next successful reply asks again.
    @Test func emptyProbeIsNotCachedAndAReplyRetries() async throws {
        try await withFixture { fx in
            let down = Provider(name: "Down", baseURL: "http://127.0.0.1:1/v1", defaultModel: "mock-plain")
            await fx.state.refreshContextInfo(provider: down, model: "mock-plain")
            #expect(fx.state.contextInfo(provider: down, model: "mock-plain") == nil)
            #expect(!fx.state.isProbingContext(provider: down, model: "mock-plain"))

            // A successful reply proves the server is up now: it retries even within the
            // empty-probe interval (same key: "Down" pointed at the mock from here on).
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-plain") == nil)
            fx.state.replyFinished(in: session)
            #expect(await waitUntil { fx.state.contextInfo(provider: fx.provider, model: "mock-plain")?.loadedContextLength == 8192 })
        }
    }

    // Two reloads of a model that is not loaded would both load it (two copies on the server).
    @Test func concurrentReloadIsRefused() async throws {
        try await withFixture { fx in
            async let first: Bool = { (try? await fx.state.reloadModel(provider: fx.provider, model: "mock-notloaded", contextLength: 12000)) != nil }()
            async let second: Bool = { (try? await fx.state.reloadModel(provider: fx.provider, model: "mock-notloaded", contextLength: 16000)) != nil }()
            let results = await [first, second]
            #expect(results.filter { $0 }.count == 1)
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-notloaded", force: true)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-notloaded")?.instanceIDs == ["mock-notloaded"])
        }
    }

    // A conversation on instance "mock-plain:2" switches to the instance the reload created.
    @Test func reloadOfAnInstanceSwitchesTheConversation() async throws {
        try await withFixture { fx in
            var load = URLRequest(url: URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + "/api/v1/models/load")!)
            load.httpMethod = "POST"
            load.setValue("application/json", forHTTPHeaderField: "Content-Type")
            load.httpBody = Data(#"{"model":"mock-plain","context_length":4096}"#.utf8)
            _ = try await URLSession(configuration: .ephemeral).data(for: load)
            let session = try await fx.create()
            session.conversation.settings.model = "mock-plain:2"

            try await fx.state.reloadModel(provider: fx.provider, model: "mock-plain:2", contextLength: 12000, session: session)
            #expect(session.conversation.settings.model == "mock-plain")
            let info = try #require(fx.state.contextInfo(provider: fx.provider, model: "mock-plain"))
            #expect(info.loadedContextLength == 12000 && info.instanceIDs == ["mock-plain"])
            guard case .finished(let note?) = fx.state.reloadState(provider: fx.provider, model: "mock-plain") else {
                Issue.record("no finished reload state for the new id")
                return
            }
            #expect(note.contains("now uses mock-plain"))
        }
    }

    // MARK: Strata (tools/mock_server.py strata-share: no API key, like a Strata without one)

    private func lastRequest(_ fx: Fixture) async throws -> [String: Any] {
        let url = URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + "/mock/last-request")!
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // The shared port is recognized, its unknown context falls back to the user's value, and the
    // request carries Strata's own fields; Max Tokens is sent as set (Strata shortens it to fit).
    @Test func strataShareFlow() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            let info = try #require(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen"))
            #expect(info.serverKind == .strata && info.loadedContextLength == nil)
            fx.settings.setManualContextLength(8192, providerID: fx.provider.id, model: "strata-qwen")

            let session = try await fx.create()
            session.conversation.settings.maxTokens = 9000
            session.conversation.settings.disablesThinking = true
            try await fx.send("hello", in: session)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.reasoning == nil)
            #expect(reply.stats?.finishReason == "stop" && reply.stats?.tokensPerSecond == 61.5)
            #expect(reply.stats?.cachedPromptTokens != nil)
            var sent = try await lastRequest(fx)
            #expect(sent["return_progress"] as? Bool == true)
            #expect(sent["reasoning_effort"] as? String == "none")
            #expect(sent["max_tokens"] as? Int == 9000)     // more than the 8192 context: Strata's to shorten

            session.conversation.settings.maxTokens = 2000
            try await fx.send("again", in: session)
            sent = try await lastRequest(fx)
            #expect(sent["max_tokens"] as? Int == 2000)
            #expect(try readPlain(session.fileURL).settings.disablesThinking == true)
        }
    }

    // The same settings against a server that is not Strata: nothing Strata-specific is sent
    // ("None" goes in LM Studio's best-effort shape, see the "No thinking" tests below).
    @Test func strataFieldsStayOffOtherServers() async throws {
        try await withFixture { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-plain")
            #expect(fx.state.contextInfo(provider: fx.provider, model: "mock-plain")?.serverKind == .lmStudio)
            let session = try await fx.create()
            session.conversation.settings.disablesThinking = true
            session.conversation.settings.reasoningBudgetTokens = 512
            session.conversation.settings.maxTokens = 100_000
            try await fx.send("hello", in: session)
            let sent = try await lastRequest(fx)
            #expect(sent["return_progress"] == nil && sent["reasoning_budget_tokens"] == nil)
            #expect(sent["reasoning_effort"] as? String == "none" && sent["chat_template_kwargs"] == nil)
            #expect(sent["max_tokens"] as? Int == 100_000)
        }
    }

    // MARK: "None (no thinking)" on every server

    private func counters(_ fx: Fixture) async throws -> [String: Int] {
        let url = URL(string: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "") + "/mock/requests")!
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Int] ?? [:]
    }

    /// A conversation set to "None" for `model`.
    private func noneSession(_ fx: Fixture, model: String) async throws -> ConversationSession {
        let session = try await fx.create()
        session.conversation.settings.model = model
        session.conversation.settings.disablesThinking = true
        return session
    }

    // llama.cpp and vLLM get chat_template_kwargs (and no reasoning_effort, which old vLLM refuses);
    // the mock honours it like the real servers, so the reply has no thinking and no note.
    @Test(arguments: ["llamacpp", "vllm"])
    func templateServersHonourNone(flavor: String) async throws {
        try await withFixture(model: "mock-reasoning-content", flavor: flavor) { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-reasoning-content")
            let kind = fx.state.contextInfo(provider: fx.provider, model: "mock-reasoning-content")?.serverKind
            #expect(kind == (flavor == "vllm" ? .vLLM : .llamaCpp))
            let session = try await noneSession(fx, model: "mock-reasoning-content")
            try await fx.send("hello", in: session)
            let sent = try await lastRequest(fx)
            #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
            #expect(sent["reasoning_effort"] == nil)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.reasoning == nil && reply.content == echo("hello"))
            #expect(reply.thinkingOffIgnored == nil && reply.thinkingOffNotAccepted == nil)
            #expect(MessageRow.thinkingOffNote(reply) == nil)
        }
    }

    // Ollama: reasoning_effort "none" (its think=false), honoured.
    @Test func ollamaHonoursNone() async throws {
        try await withFixture(model: "mock-reasoning", flavor: "ollama") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-reasoning")
            let session = try await noneSession(fx, model: "mock-reasoning")
            try await fx.send("hello", in: session)
            let sent = try await lastRequest(fx)
            #expect(sent["reasoning_effort"] as? String == "none" && sent["chat_template_kwargs"] == nil)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.reasoning == nil && reply.thinkingOffIgnored == nil)
        }
    }

    // LM Studio (the mock ignores the field, as an unconfirmed server may): thinking still comes,
    // inline <think> tags included, and the reply says so, also after reopening the file.
    @Test(arguments: ["mock-reasoning-content", "mock-think-tags"])
    func ignoredNoneIsNotedAndPersisted(model: String) async throws {
        try await withFixture(model: model) { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: model)
            let session = try await noneSession(fx, model: model)
            try await fx.send("hello", in: session)
            #expect(try await lastRequest(fx)["reasoning_effort"] as? String == "none")
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && !(reply.reasoning ?? "").isEmpty)
            #expect(reply.thinkingOffIgnored == true && reply.thinkingOffNotAccepted == nil)
            // The kind the request was shaped for is stored with the note (its hint).
            #expect(reply.thinkingOffServerKind == "lmStudio")
            let note = try #require(MessageRow.thinkingOffNote(reply))
            #expect(note.contains("ignored") && note.contains("LM Studio"))

            let disk = try readPlain(session.fileURL)
            #expect(disk.messages.last?.thinkingOffIgnored == true && disk.messages.last?.thinkingOffServerKind == "lmStudio")
            #expect(disk.settings.disablesThinking == true && disk.settings.reasoningEffort == nil)

            // A reply without thinking, or one sent without "None", gets no note.
            session.conversation.settings.model = "mock-plain"
            try await fx.send("plain", in: session)
            #expect(session.conversation.messages.last?.thinkingOffIgnored == nil)
            session.conversation.settings.model = model
            session.conversation.settings.disablesThinking = nil
            try await fx.send("default", in: session)
            #expect(session.conversation.messages.last?.thinkingOffIgnored == nil)
            #expect(try await lastRequest(fx)["reasoning_effort"] == nil)
        }
    }

    // A server that refuses the field (OpenAI's 400 naming the param) gets the request once more
    // without it; the reply says it used the server's default. Remembered for this provider and
    // model in this AppState only: later replies leave the field out and still say so.
    @Test func refusedNoneIsRetriedOnceAndRemembered() async throws {
        try await withFixture(model: "mock-reasoning-content", flavor: "openai-strict") { fx in
            let model = "mock-reasoning-content"
            await fx.state.refreshContextInfo(provider: fx.provider, model: model)
            #expect(fx.state.contextInfo(provider: fx.provider, model: model)?.serverKind == nil)
            let session = try await noneSession(fx, model: model)
            try await fx.send("hello", in: session)
            var reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.content == echo("hello") && reply.reasoning != nil)
            #expect(reply.thinkingOffNotAccepted == true && reply.thinkingOffIgnored == nil)
            #expect(MessageRow.thinkingOffNote(reply)?.contains("did not accept") == true)
            var count = try await counters(fx)
            #expect(count["chat"] == 2 && count["thinking_off_rejected"] == 1)
            #expect(try await lastRequest(fx)["reasoning_effort"] == nil)
            #expect(fx.state.isThinkingOffRejected(provider: fx.provider, model: model))
            #expect(!fx.state.isThinkingOffRejected(provider: fx.provider, model: "mock-plain"))
            #expect(try readPlain(session.fileURL).messages.last?.thinkingOffNotAccepted == true)

            // Remembered: one request, without the field, and the same note.
            try await fx.send("again", in: session)
            reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.thinkingOffNotAccepted == true && reply.thinkingOffIgnored == nil)
            count = try await counters(fx)
            #expect(count["chat"] == 3 && count["thinking_off_rejected"] == 1)

            // A reset (or another AppState: a later launch) starts over.
            fx.state.resetThinkingOffRejections()
            try await fx.send("fresh", in: session)
            count = try await counters(fx)
            #expect(count["chat"] == 5 && count["thinking_off_rejected"] == 2)
        }
    }

    // Retried only once (a server that refuses everything ends with its error), never for other
    // 400s (a generic error, an overflow) and never when "None" was not chosen. A retry that is
    // refused too shows the first error, with no note, and nothing is remembered.
    @Test func onlyARefusalOfTheFieldIsRetried() async throws {
        try await withFixture(model: "mock-plain", flavor: "openai-strict") { fx in
            let session = try await noneSession(fx, model: "mock-always-reject")
            try await fx.send("hello", in: session)
            var reply = try #require(session.conversation.messages.last)
            #expect(reply.error?.contains("reasoning_effort") == true)
            #expect(reply.thinkingOffNotAccepted == nil && MessageRow.thinkingOffNote(reply) == nil)
            #expect(!fx.state.isThinkingOffRejected(provider: fx.provider, model: "mock-always-reject"))
            var count = try await counters(fx)
            #expect(count["chat"] == 2 && count["thinking_off_rejected"] == 2)
            // Not remembered: the next send tries "None" again.
            try await fx.send("again", in: session)
            count = try await counters(fx)
            #expect(count["chat"] == 4 && count["thinking_off_rejected"] == 4)

            for model in ["mock-error", "mock-overflow"] {
                session.conversation.settings.model = model
                try await fx.send("hello", in: session)
                reply = try #require(session.conversation.messages.last)
                #expect(reply.error != nil && reply.thinkingOffNotAccepted == nil, "\(model)")
                #expect(!fx.state.isThinkingOffRejected(provider: fx.provider, model: model))
            }
            count = try await counters(fx)
            #expect(count["chat"] == 6)

            session.conversation.settings.disablesThinking = nil
            session.conversation.settings.model = "mock-always-reject"
            try await fx.send("hello", in: session)
            count = try await counters(fx)
            #expect(count["chat"] == 7)
        }
    }

    // A refusal that does not name the field (Ollama's "invalid reasoning value") is retried too,
    // and counts as one because the retry without the field is accepted.
    @Test func unnamedRefusalIsRetriedAndRemembered() async throws {
        try await withFixture(model: "mock-plain", flavor: "openai-strict") { fx in
            let model = "mock-refuse-unnamed"
            let session = try await noneSession(fx, model: model)
            try await fx.send("hello", in: session)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.content == echo("hello") && reply.thinkingOffNotAccepted == true)
            var count = try await counters(fx)
            #expect(count["chat"] == 2 && count["thinking_off_rejected"] == 1)
            #expect(fx.state.isThinkingOffRejected(provider: fx.provider, model: model, fields: ["reasoning_effort"]))
            try await fx.send("again", in: session)
            count = try await counters(fx)
            #expect(count["chat"] == 3 && count["thinking_off_rejected"] == 1)
            #expect(session.conversation.messages.last?.thinkingOffNotAccepted == true)
        }
    }

    // A remembered refusal is noted only once the server answered: a reply that then fails with
    // another error carries the error alone.
    @Test func rememberedRefusalIsNotedOnlyOnAnAnswer() async throws {
        try await withFixture(model: "mock-plain", flavor: "openai-strict") { fx in
            fx.state.markThinkingOffRejected(provider: fx.provider, model: "mock-error", fields: ["reasoning_effort"])
            let session = try await noneSession(fx, model: "mock-error")
            try await fx.send("hello", in: session)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error != nil && reply.thinkingOffNotAccepted == nil)
            #expect(try await lastRequest(fx)["reasoning_effort"] == nil)
            #expect(try await counters(fx)["chat"] == 1)
        }
    }

    // The memory is per field: "reasoning_effort" refused while the kind was unknown does not stop
    // llama.cpp (identified later) from getting chat_template_kwargs; the unknown shape stays off.
    @Test func refusalMemoryIsPerField() async throws {
        try await withFixture(model: "mock-reasoning-content", flavor: "llamacpp") { fx in
            let model = "mock-reasoning-content"
            fx.state.markThinkingOffRejected(provider: fx.provider, model: model, fields: ["reasoning_effort"])
            #expect(fx.state.isThinkingOffRejected(provider: fx.provider, model: model, fields: ["reasoning_effort"]))
            #expect(!fx.state.isThinkingOffRejected(provider: fx.provider, model: model, fields: ["chat_template_kwargs"]))
            await fx.state.refreshContextInfo(provider: fx.provider, model: model)
            #expect(fx.state.contextInfo(provider: fx.provider, model: model)?.serverKind == .llamaCpp)
            let session = try await noneSession(fx, model: model)
            try await fx.send("hello", in: session)
            let sent = try await lastRequest(fx)
            #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.reasoning == nil)
            #expect(reply.thinkingOffNotAccepted == nil && reply.thinkingOffIgnored == nil)
        }
    }

    // Both retries in one reply: stream_options first, then "no thinking".
    @Test func streamOptionsAndNoneRetriesCombine() async throws {
        try await withFixture(model: "mock-no-stream-options", flavor: "openai-strict") { fx in
            let session = try await noneSession(fx, model: "mock-no-stream-options")
            try await fx.send("hello", in: session)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.content == echo("hello") && reply.thinkingOffNotAccepted == true)
            let count = try await counters(fx)
            #expect(count["chat"] == 3 && count["stream_options_rejected"] == 1 && count["thinking_off_rejected"] == 1)
        }
    }

    // Fresh launch, first send: the probe has not finished. A send with "None" waits for it, so
    // llama.cpp gets its own shape instead of the unknown-server one; "Not sent" never waits.
    @Test func noneWaitsForTheProbe() async throws {
        try await withFixture(model: "mock-reasoning-content", flavor: "llamacpp", environment: ["MOCK_PROBE_DELAY": "1"]) { fx in
            let model = "mock-reasoning-content"
            let plain = try await fx.create()
            try await fx.send("plain", in: plain)
            #expect(!fx.state.isProbingContext(provider: fx.provider, model: model))
            #expect(fx.state.contextInfo(provider: fx.provider, model: model) == nil)

            let session = try await noneSession(fx, model: model)
            session.send(text: "hello", attachments: [], settings: fx.settings)
            // The send started the probe and waits for it (no request until it is done).
            #expect(await waitUntil(timeout: 0.8) { fx.state.isProbingContext(provider: fx.provider, model: model) })
            #expect(try await counters(fx)["chat"] == 1)
            try await fx.waitForReply(session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: model)?.serverKind == .llamaCpp)
            let sent = try await lastRequest(fx)
            #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
            #expect(sent["reasoning_effort"] == nil)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.error == nil && reply.reasoning == nil && reply.thinkingOffIgnored == nil)
            // Time to first token is the server's, not the probe's second.
            #expect((reply.stats?.timeToFirstToken ?? 9) < 0.9)
        }
    }

    // The same race for Strata's thinking budget, which only Strata gets: without the wait the
    // first reply after launch would silently drop it (and Strata's progress flag).
    @Test func thinkingBudgetWaitsForTheProbe() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-engine", environment: ["MOCK_PROBE_DELAY": "1"]) { fx in
            let session = try await fx.create()
            session.conversation.settings.reasoningBudgetTokens = 256
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen") == nil)
            try await fx.send("hello", in: session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen")?.serverKind == .strata)
            let sent = try await lastRequest(fx)
            #expect(sent["reasoning_budget_tokens"] as? Int == 256 && sent["return_progress"] as? Bool == true)
            #expect(session.conversation.messages.last?.error == nil)
        }
    }

    // A thinking budget waits longer than "None" (one probe GET): Strata identified after the
    // short wait would otherwise lose the budget silently.
    @Test func thinkingBudgetWaitsLongerThanNone() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-engine", environment: ["MOCK_PROBE_DELAY": "1"]) { fx in
            fx.state.serverInfoWaitTimeout = 0.2
            #expect(fx.state.serverInfoBudgetWaitTimeout > 5)
            let session = try await fx.create()
            session.conversation.settings.reasoningBudgetTokens = 256
            try await fx.send("hello", in: session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen")?.serverKind == .strata)
            let sent = try await lastRequest(fx)
            #expect(sent["reasoning_budget_tokens"] as? Int == 256 && sent["return_progress"] as? Bool == true)
        }
    }

    // Stop during that wait ends it at once and no chat request is ever sent; a wait that runs out
    // sends the best-effort shape.
    @Test func stopDuringTheProbeWaitSendsNothing() async throws {
        try await withFixture(model: "mock-reasoning-content", flavor: "llamacpp", environment: ["MOCK_PROBE_DELAY": "2"]) { fx in
            let model = "mock-reasoning-content"
            let session = try await noneSession(fx, model: model)
            session.send(text: "hello", attachments: [], settings: fx.settings)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(session.isStreaming)
            session.stop()
            #expect(!session.isStreaming)
            let stopped = try #require(session.conversation.messages.last)
            #expect(!stopped.isComplete && stopped.error == nil)
            try #require(await waitUntil { !fx.state.isProbingContext(provider: fx.provider, model: model) })
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(try await counters(fx)["chat"] == 0)

            // A probe slower than the wait: sent without the server kind.
            fx.state.serverInfoWaitTimeout = 0.2
            let other = try await noneSession(fx, model: "mock-reasoning")
            try await fx.send("hello", in: other)
            #expect(try await counters(fx)["chat"] == 1)
            #expect(try await lastRequest(fx)["reasoning_effort"] as? String == "none")
        }
    }

    // A model without picture reading refuses images; the refusal is remembered so the composer
    // can warn before the next image, and the error reads as what to do.
    @Test func strataVisionRefusalIsRemembered() async throws {
        try await withFixture(model: "strata-novision", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-novision")
            let session = try await fx.create()
            let image = Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50]))
            session.send(text: "look", attachments: [image], settings: fx.settings)
            try await fx.waitForReply(session)
            let error = try #require(session.conversation.messages.last?.error)
            fx.state.replyFinished(in: session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-novision")?.acceptsImages == false)
            #expect(ErrorPresentation.make(error, serverKind: .strata).title == "This Strata model does not read images")
            // A later probe does not forget it (the shared port cannot report vision).
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-novision", force: true)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-novision")?.acceptsImages == false)
        }
    }

    // An overflow error names the context: an unknown limit is filled from it.
    @Test func strataOverflowFillsTheLimit() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            let session = try await fx.create()
            try await fx.send(String(repeating: "word ", count: 8000), in: session)
            let error = try #require(session.conversation.messages.last?.error)
            fx.state.replyFinished(in: session)
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen")?.loadedContextLength == nil)
            #expect(ErrorPresentation.make(error).title == "The conversation no longer fits in the model's context")
        }
    }

    // Prompt reading is published while the reply waits for its first token (Strata's engine;
    // the share port sends no progress, so there only the waiting time shows).
    @Test func strataPromptProgressIsLive() async throws {
        try await withFixture(model: "strata-slow", flavor: "strata-engine") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-slow")
            let session = try await fx.create()
            session.send(text: "slow", attachments: [], settings: fx.settings)
            try #require(await waitUntil { session.liveGeneration?.promptProgress != nil })
            let progress = try #require(session.liveGeneration?.promptProgress)
            #expect(progress.total > 0 && progress.fraction < 1)
            try #require(await waitUntil { !(session.conversation.messages.last?.content.isEmpty ?? true) })
            #expect(session.liveGeneration?.promptProgress == nil)
            session.stop()
        }
    }

    // The user's real setup: the shared port reports no context and no value was entered. A
    // fit-off overflow names the context and the room; a retry with Max Tokens lowered to it succeeds.
    @Test func strataOverflowLimitFeedsTheRetry() async throws {
        try await withFixture(model: "strata-nofit", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-nofit")
            let session = try await fx.create()
            session.conversation.settings.maxTokens = 9000
            try await fx.send("hello", in: session)
            #expect(session.conversation.messages.last?.error != nil)
            #expect(try await lastRequest(fx)["max_tokens"] as? Int == 9000)
            fx.state.replyFinished(in: session)
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-nofit") == ContextLimit(tokens: 8192, source: .learned))
            let error = try #require(session.conversation.messages.last?.error)
            let room = try #require(ContextBudget.strataOverflow(fromError: error)?.room)
            #expect(ErrorPresentation.make(error).detail?.contains("to at most \(TokenFormat.grouped(room))") == true)

            session.conversation.settings.maxTokens = room
            session.regenerate(messageAt: session.conversation.messages.count - 1, settings: fx.settings)
            try await fx.waitForReply(session)
            #expect(session.conversation.messages.last?.error == nil)
            #expect(try await lastRequest(fx)["max_tokens"] as? Int == room)
        }
    }


    // MARK: Strata over two routes (Tailscale and a Cloudflare Tunnel: same instance id)

    /// A second provider for the same mock, reached through its /cf prefix (Cloudflare's headers on
    /// every answer), as the user's Cloudflare Tunnel route reaches the same Strata.
    private func cloudflareRoute(_ fx: Fixture) -> Provider {
        let route = Provider(name: "Strata (Cloudflare)", baseURL: fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "/cf/v1"),
                             defaultModel: fx.provider.defaultModel)
        fx.settings.providers.append(route)
        return route
    }

    // An overflow on one route teaches every route to the same Strata instance, survives a relaunch,
    // and gives way to the user's own value, which is shared the same way.
    @Test func strataContextIsSharedAcrossRoutes() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            let tunnel = cloudflareRoute(fx)
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            await fx.state.refreshContextInfo(provider: tunnel, model: "strata-qwen")
            #expect(fx.state.contextInstanceID(provider: fx.provider, model: "strata-qwen") == "inst-0")
            #expect(fx.state.contextInstanceID(provider: tunnel, model: "strata-qwen") == "inst-0")
            #expect(fx.state.contextLimit(provider: tunnel, model: "strata-qwen") == nil)

            // The overflow happens on the direct route…
            let session = try await fx.create()
            try await fx.send(String(repeating: "word ", count: 8000), in: session)
            fx.state.replyFinished(in: session)
            // …and the tunnel route knows the size too.
            #expect(fx.state.contextLimit(provider: tunnel, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))

            // Persisted: a relaunch (new AppState and settings on the same defaults) shows it before any probe.
            let relaunched = AppState(settings: AppSettings(defaults: fx.defaults))
            #expect(relaunched.contextLimit(provider: tunnel, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))
            #expect(relaunched.contextLimit(provider: fx.provider, model: "strata-qwen")?.source == .learned)
            // Another model on the same server is not affected.
            #expect(relaunched.learnedContextLength(provider: tunnel, model: "strata-slow") == nil)

            // The user's value wins over the learned one, on every route.
            fx.state.setManualContextLength(131072, provider: tunnel, model: "strata-qwen")
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 131072, source: .manual))
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "strata-qwen") == 8192)
            // Cleared from the other route, it is gone everywhere: the learned value applies again.
            fx.state.setManualContextLength(nil, provider: fx.provider, model: "strata-qwen")
            #expect(fx.state.contextLimit(provider: tunnel, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))
            #expect(AppSettings(defaults: fx.defaults).contextLengthOverrides.isEmpty)
        }
    }

    // A later overflow naming another size replaces the learned one, and the user's older value.
    // A value typed before the instance was known (stored per provider) moves to the instance, so
    // the other route gets it.
    @Test func strataLearnedValueUpdatesAndOldValuesMove() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            fx.settings.setManualContextLength(65536, providerID: fx.provider.id, model: "strata-qwen")
            fx.settings.setLearnedContextLength(4096, providerID: fx.provider.id, model: "strata-qwen")
            let tunnel = cloudflareRoute(fx)
            #expect(fx.state.manualContextLength(provider: tunnel, model: "strata-qwen") == nil)
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            await fx.state.refreshContextInfo(provider: tunnel, model: "strata-qwen")
            #expect(fx.state.manualContextLength(provider: tunnel, model: "strata-qwen") == 65536)
            #expect(fx.settings.contextLengthOverrides[AppSettings.contextKey(providerID: fx.provider.id, model: "strata-qwen")] == nil)

            let session = try await fx.create()
            session.conversation.settings.providerID = tunnel.id
            try await fx.send(String(repeating: "word ", count: 8000), in: session)
            fx.state.replyFinished(in: session)
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "strata-qwen") == 8192)
            // The overflow is newer than the typed 65536 and contradicts it: the server's size wins.
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))
            #expect(fx.state.manualContextLength(provider: tunnel, model: "strata-qwen") == nil)
        }
    }

    // The newer of the user's value and the overflow's size wins.
    @Test func newerContextValueWins() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            // Typed, then Strata's setup changed: the next overflow names the real size.
            fx.state.setManualContextLength(131072, provider: fx.provider, model: "strata-qwen")
            let session = try await fx.create()
            try await fx.send(String(repeating: "word ", count: 8000), in: session)
            fx.state.replyFinished(in: session)
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .learned))
            #expect(fx.state.manualContextLength(provider: fx.provider, model: "strata-qwen") == nil)
            #expect(AppSettings(defaults: fx.defaults).contextLengthOverrides.isEmpty)

            // Typed after the overflow: the user's value wins.
            fx.state.setManualContextLength(16384, provider: fx.provider, model: "strata-qwen")
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 16384, source: .manual))
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "strata-qwen") == 8192)

            // An overflow naming the same size as the user's value changes nothing.
            fx.state.setManualContextLength(8192, provider: fx.provider, model: "strata-qwen")
            try await fx.send(String(repeating: "word ", count: 8000), in: session)
            fx.state.replyFinished(in: session)
            #expect(fx.state.contextLimit(provider: fx.provider, model: "strata-qwen") == ContextLimit(tokens: 8192, source: .manual))
        }
    }

    // Strata started the model again under a new id (seen live for the same model): the user's value
    // follows, the learned one does not, every route follows to the new id, and the old id's values
    // are removed, so a value cleared on one route cannot come back from another.
    @Test func restartedStrataInstanceCarriesOnlyTheUsersValue() throws {
        let root = try makeTempRoot()
        let suiteName = defaultsSuiteName(in: root)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { removeDefaultsSuite(suiteName, defaults, root: root) }
        let settings = AppSettings(defaults: defaults)
        let a = UUID(), b = UUID(), m = "iq3_s"
        let urlA = "http://100.101.102.103:47832/v1", urlB = "https://strata.example.net/v1"
        settings.linkInstance("X1", providerID: a, model: m, baseURL: urlA)
        settings.linkInstance("X1", providerID: b, model: m, baseURL: urlB)
        settings.setManualContextLength(131072, providerID: a, model: m, instanceID: "X1")
        settings.setLearnedContextLength(131072, providerID: b, model: m, instanceID: "X1")
        #expect(settings.manualContextLength(providerID: b, model: m, instanceID: "X1") == 131072)

        // Route A sees the new id first.
        settings.linkInstance("X2", providerID: a, model: m, baseURL: urlA)
        #expect(settings.manualContextLength(providerID: a, model: m, instanceID: "X2") == 131072)
        #expect(settings.learnedContextLength(providerID: a, model: m, instanceID: "X2") == nil)
        #expect(settings.linkedInstanceID(providerID: b, model: m, baseURL: urlB) == "X2")
        #expect(!settings.contextLengthOverrides.keys.contains { $0.contains("X1") })
        #expect(settings.learnedContextLengths.isEmpty)

        // Clear on A, then B's probe sees X2: nothing comes back.
        settings.setManualContextLength(nil, providerID: a, model: m, instanceID: "X2")
        settings.linkInstance("X2", providerID: b, model: m, baseURL: urlB)
        #expect(settings.manualContextLength(providerID: b, model: m, instanceID: "X2") == nil)
        #expect(settings.contextLengthOverrides.isEmpty)

        // Persisted (links with their address) and read back after a relaunch.
        settings.setManualContextLength(65536, providerID: b, model: m, instanceID: "X2")
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.contextInstanceLinks == settings.contextInstanceLinks)
        #expect(relaunched.linkedInstanceID(providerID: a, model: m, baseURL: urlA + "/") == "X2")
        #expect(relaunched.manualContextLength(providerID: a, model: m, instanceID: "X2") == 65536)
    }

    // Within one launch: when one route sees Strata's new id, the other route (probed earlier, its
    // cached probe still naming the old id) follows at once and keeps the user's value.
    @Test func otherRouteFollowsARestartedInstance() async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            let tunnel = cloudflareRoute(fx)
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            await fx.state.refreshContextInfo(provider: tunnel, model: "strata-qwen")
            fx.state.setManualContextLength(32768, provider: tunnel, model: "strata-qwen")
            fx.settings.linkInstance("inst-1", providerID: fx.provider.id, model: "strata-qwen", baseURL: fx.provider.baseURL)
            #expect(fx.state.contextInfo(provider: tunnel, model: "strata-qwen")?.serverInstanceID == "inst-0")
            #expect(fx.state.contextInstanceID(provider: tunnel, model: "strata-qwen") == "inst-1")
            #expect(fx.state.contextLimit(provider: tunnel, model: "strata-qwen") == ContextLimit(tokens: 32768, source: .manual))
        }
    }

    // A provider pointed at another address: its link stops counting at once, and the instance it
    // finds there starts empty (another Strata serving the same model name has its own values).
    @Test func repointedStrataProviderStartsFresh() throws {
        let root = try makeTempRoot()
        let suiteName = defaultsSuiteName(in: root)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { removeDefaultsSuite(suiteName, defaults, root: root) }
        let settings = AppSettings(defaults: defaults)
        let a = UUID(), m = "iq3_s"
        let oldURL = "http://100.101.102.103:47832/v1", newURL = "http://192.168.1.30:47832/v1"
        settings.linkInstance("Y1", providerID: a, model: m, baseURL: oldURL)
        settings.setManualContextLength(32768, providerID: a, model: m, instanceID: "Y1")
        settings.setLearnedContextLength(32768, providerID: a, model: m, instanceID: "Y1")
        #expect(settings.linkedInstanceID(providerID: a, model: m, baseURL: newURL) == nil)
        settings.linkInstance("Z1", providerID: a, model: m, baseURL: newURL)
        #expect(settings.manualContextLength(providerID: a, model: m, instanceID: "Z1") == nil)
        #expect(settings.learnedContextLength(providerID: a, model: m, instanceID: "Z1") == nil)
        // Nothing links to Y1 any more.
        #expect(settings.contextLengthOverrides.isEmpty && settings.learnedContextLengths.isEmpty)
        // A link stored by an earlier build (a bare id string) is ignored, not misread.
        defaults.set(["\(a.uuidString)|\(m)": "Y1"], forKey: "contextInstanceLinks")
        #expect(AppSettings(defaults: defaults).linkedInstanceID(providerID: a, model: m, baseURL: oldURL) == nil)
    }

    // A provider repointed from Strata to another server stops sharing the old instance's values.
    @Test func repointedProviderDropsTheInstanceLink() async throws {
        let lmStudio = try await startMockServer()
        do {
            try await repointedProviderBody(lmStudio)
        } catch {
            await lmStudio.stop()
            throw error
        }
        await lmStudio.stop()
    }

    private func repointedProviderBody(_ lmStudio: MockServer) async throws {
        try await withFixture(model: "strata-qwen", flavor: "strata-share") { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-qwen")
            #expect(fx.state.contextInstanceID(provider: fx.provider, model: "strata-qwen") == "inst-0")
            fx.state.setManualContextLength(32768, provider: fx.provider, model: "strata-qwen")
            fx.settings.providers[0].baseURL = lmStudio.baseURL
            let moved = fx.settings.providers[0]
            // Before any probe at the new address the old link already does not count.
            #expect(fx.state.contextInstanceID(provider: moved, model: "strata-qwen") == nil)
            #expect(fx.state.manualContextLength(provider: moved, model: "strata-qwen") == nil)
            await fx.state.refreshContextInfo(provider: moved, model: "strata-qwen")
            #expect(fx.state.contextInstanceID(provider: moved, model: "strata-qwen") == nil)
            fx.state.setManualContextLength(4096, provider: moved, model: "strata-qwen")
            #expect(fx.settings.contextLengthOverrides[AppSettings.contextKey(providerID: moved.id, model: "strata-qwen")] == 4096)
            // No provider reaches inst-0 any more: its values are removed.
            #expect(fx.settings.contextLengthOverrides[AppSettings.contextKey(instanceID: "inst-0", model: "strata-qwen")] == nil)
        }
    }

    // Without an instance id (any other server) values stay per provider and model, as before.
    @Test func learnedValuesStayPerProviderElsewhere() async throws {
        try await withFixture { fx in
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-plain")
            #expect(fx.state.contextInstanceID(provider: fx.provider, model: "mock-plain") == nil)
            let other = Provider(name: "Other", baseURL: fx.provider.baseURL)
            fx.settings.providers.append(other)
            fx.settings.setLearnedContextLength(4000, providerID: other.id, model: "mock-notloaded")
            #expect(fx.state.learnedContextLength(provider: other, model: "mock-notloaded") == 4000)
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "mock-notloaded") == nil)
            // The loaded size the server reports wins over a learned one…
            fx.settings.setLearnedContextLength(4000, providerID: fx.provider.id, model: "mock-plain")
            #expect(fx.state.contextLimit(provider: fx.provider, model: "mock-plain") == ContextLimit(tokens: 8192, source: .server))
            // …and replaces it at the next probe, so it cannot outlive a later unload.
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-plain", force: true)
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "mock-plain") == nil)
            // A model the server reports no loaded size for keeps its learned value.
            fx.settings.setLearnedContextLength(4000, providerID: fx.provider.id, model: "mock-notloaded")
            await fx.state.refreshContextInfo(provider: fx.provider, model: "mock-notloaded", force: true)
            #expect(fx.state.learnedContextLength(provider: fx.provider, model: "mock-notloaded") == 4000)
        }
    }

    // A reply cut off mid-stream keeps its text and reads as an interruption, not "can't reach".
    @Test func droppedStreamKeepsThePartialReply() async throws {
        try await withFixture(model: "mock-drop") { fx in
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            let reply = try #require(session.conversation.messages.last)
            #expect(reply.content.hasPrefix("Partial answer") && !reply.isComplete)
            let error = try #require(reply.error)
            let p = ErrorPresentation.make(error, providerName: "Mock", partialReply: true)
            #expect(p.title == "The connection dropped before the reply finished")
            #expect(p.detail?.hasPrefix("The text received so far is kept.") == true && p.retryable && !p.suggestsSettings)
            let disk = try #require(try readPlain(session.fileURL).messages.last)
            #expect(disk.content == reply.content && disk.error == error)
        }
    }

    // Cloudflare's 524 through the app: stored as one line, shown as what to do.
    @Test func cloudflareTimeoutReadsAsGuidance() async throws {
        try await withFixture(model: "mock-plain") { fx in
            fx.settings.providers[0].baseURL = fx.provider.baseURL.replacingOccurrences(of: "/v1", with: "/cf-524/v1")
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            let error = try #require(session.conversation.messages.last?.error)
            #expect(error.hasPrefix("HTTP 524: Cloudflare error 524: A timeout occurred") && !error.contains("<"))
            let p = ErrorPresentation.make(error, providerName: "Strata", serverKind: .strata)
            #expect(p.title == "No answer within Cloudflare's 100-second limit")
            #expect(p.detail?.contains("Tailscale") == true)
            let disk = try readFile(session.fileURL)
            #expect(!disk.isEmpty && !contains(disk, "<!DOCTYPE"))
        }
    }
}
