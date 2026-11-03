import Foundation
import Testing
@testable import Parley
import ParleyCore

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

private let python3Path = "/usr/bin/python3"

private let mockServerScript: URL = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()   // ParleyAppTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("tools/mock_server.py")

private struct FlowTestError: Error, CustomStringConvertible {
    let description: String
}

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

/// Set from the process's termination handler (a background queue).
private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    func set() { lock.lock(); exited = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return exited }
}

/// A running mock server.
private struct MockServer {
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
private func startMockServer(flavor: String? = nil) async throws -> MockServer {
    guard FileManager.default.fileExists(atPath: mockServerScript.path) else {
        throw FlowTestError(description: "mock server not found at \(mockServerScript.path)")
    }
    for _ in 0..<5 {
        let port = try freeLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3Path)
        process.arguments = ["-I", "-u", mockServerScript.path, String(port)] + (flavor.map { [$0] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = ExitFlag()
        process.terminationHandler = { _ in exited.set() }
        try process.run()

        let server = MockServer(process: process, exited: exited, baseURL: "http://127.0.0.1:\(port)/v1")
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

private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ParleyAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A unique suite name that is an absolute path inside the test's temp directory, so the suite's
/// plist lives there (CFPreferences treats an absolute path as the plist location) and goes away
/// with it. A plain reverse-DNS suite name leaves an empty plist in ~/Library/Preferences, because
/// cfprefsd writes the emptied domain back after the test has deleted the file.
private func defaultsSuiteName(in root: URL) -> String {
    root.appendingPathComponent("defaults").path
}

private func removeDefaultsSuite(_ name: String, _ suite: UserDefaults, root: URL) {
    suite.removePersistentDomain(forName: name)
    try? FileManager.default.removeItem(at: root)
}

/// One isolated app: its own defaults suite, temp directories and a provider pointing at the mock.
@MainActor
private final class Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let root: URL
    let defaultDir: URL
    let settings: AppSettings
    let state: AppState
    let provider: Provider

    init(baseURL: String, defaultModel: String) throws {
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
        state = AppState(settings: settings)
    }

    /// A directory other than the default one (created lazily by the app on first write).
    func customDirectory(_ name: String = "Custom") -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    func cleanup() {
        for session in state.sessions.values {
            session.close(saving: false)
        }
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
private func withFixture(
    model: String = "mock-plain",
    flavor: String? = nil,
    _ body: (Fixture) async throws -> Void
) async throws {
    let server = try await startMockServer(flavor: flavor)
    do {
        let fixture = try Fixture(baseURL: server.baseURL, defaultModel: model)
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
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

// MARK: - Disk helpers

/// Waits for every queued background save, then reads the file.
private func readFile(_ url: URL) throws -> Data {
    ConversationWriter.flush()
    return try Data(contentsOf: url)
}

private func readPlain(_ url: URL) throws -> Conversation {
    try ConversationFile.decodePlain(readFile(url))
}

private func contains(_ data: Data, _ text: String) -> Bool {
    data.range(of: Data(text.utf8)) != nil
}

/// Every entry in the directory, hidden files included.
private func listing(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

private func echo(_ text: String) -> String {
    #"You said: "\#(text)" (0 images received)"#
}

/// Field-wise equality. Dates are written as ISO 8601 without fractional seconds, so they only
/// round-trip to within a second.
private func expectSameMessages(_ disk: [Message], _ memory: [Message], sourceLocation: SourceLocation = #_sourceLocation) {
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

            // Lock drops the session; the library entry keeps no title.
            let id = session.id
            fx.state.lock(id)
            #expect(fx.state.notice == nil)
            #expect(fx.state.session(for: id) == nil)
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
            try await fx.state.reloadModel(provider: fx.provider, model: "mock-plain", contextLength: 12000)
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

    // The same settings against a server that is not Strata: nothing Strata-specific is sent.
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
            #expect(sent["return_progress"] == nil && sent["reasoning_effort"] == nil && sent["reasoning_budget_tokens"] == nil)
            #expect(sent["max_tokens"] as? Int == 100_000)
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
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-qwen")?.loadedContextLength == 8192)
            #expect(ErrorPresentation.make(error).title == "The conversation no longer fits in the model's context")
        }
    }

    // Prompt reading is published while the reply waits for its first token.
    @Test func strataPromptProgressIsLive() async throws {
        try await withFixture(model: "strata-slow", flavor: "strata-share") { fx in
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
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-nofit")?.loadedContextLength == 8192)
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

}
