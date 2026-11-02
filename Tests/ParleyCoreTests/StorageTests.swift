import CryptoKit
import Foundation
import Security
import Testing
@testable import ParleyCore

// Low iteration count keeps the tests fast; production uses defaultIterations.
private let testIterations = 1000

/// Whole-second dates, because the `.iso8601` strategy drops fractional seconds.
private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func sampleConversation(title: String = "Secret project plans") -> Conversation {
    let messages = [
        Message(role: .user, content: "What is the launch codename?", createdAt: date(1_700_000_000)),
        Message(
            role: .assistant,
            content: "The codename is BLUEHERON.",
            reasoning: "The user asks about the codename.",
            reasoningDuration: 1.25,
            attachments: [],
            createdAt: date(1_700_000_010),
            model: "mock-model",
            usage: TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)
        ),
        Message(
            role: .user,
            content: "Here are files",
            attachments: [
                Attachment(kind: .image, filename: "pic.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])),
                Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", text: "line one\nline two"),
            ],
            createdAt: date(1_700_000_020)
        ),
        Message(role: .assistant, content: "partial", createdAt: date(1_700_000_030), isComplete: false, error: "stopped"),
    ]
    return Conversation(
        title: title,
        createdAt: date(1_699_999_000),
        updatedAt: date(1_700_000_030),
        settings: ConversationSettings(
            providerID: UUID(), model: "mock-model", systemPrompt: "Be terse.",
            temperature: 0.7, maxTokens: 512, reasoningEffort: .high
        ),
        messages: messages
    )
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-storage-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
}

/// Parses an encoded file, lets the caller edit the top-level dictionary, and re-serializes it.
private func mutate(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&dict)
    return try JSONSerialization.data(withJSONObject: dict)
}

private func expectCorrupt(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    let error = #expect(throws: ParleyError.self, sourceLocation: sourceLocation) { try body() }
    guard case .corruptFile = error else {
        Issue.record("expected corruptFile, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
}

// MARK: - Crypto

@Suite("Crypto")
struct CryptoTests {
    @Test func defaultIterationsIs600k() {
        #expect(ConversationCrypto.defaultIterations == 600_000)
        #expect(ConversationCrypto.kdfName == "PBKDF2-HMAC-SHA256")
        #expect(ConversationCrypto.cipherName == "AES-256-GCM")
    }

    @Test func deriveKeyIsDeterministicAnd32Bytes() throws {
        let salt = Data(repeating: 7, count: 16)
        let a = try ConversationCrypto.deriveKey(password: "pw", salt: salt, iterations: testIterations)
        let b = try ConversationCrypto.deriveKey(password: "pw", salt: salt, iterations: testIterations)
        let c = try ConversationCrypto.deriveKey(password: "pw2", salt: salt, iterations: testIterations)
        let d = try ConversationCrypto.deriveKey(password: "pw", salt: Data(repeating: 8, count: 16), iterations: testIterations)
        #expect(a.bitCount == 256)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test func deriveKeyMatchesKnownPBKDF2Vector() throws {
        // RFC 7914 section 11 PBKDF2-HMAC-SHA256 vector: P="passwd", S="salt", c=1, first 32 bytes.
        let key = try ConversationCrypto.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    @Test func deriveKeyNormalizesUnicode() throws {
        let salt = Data(repeating: 1, count: 16)
        let composed = try ConversationCrypto.deriveKey(password: "caf\u{00E9}", salt: salt, iterations: testIterations)
        let decomposed = try ConversationCrypto.deriveKey(password: "cafe\u{0301}", salt: salt, iterations: testIterations)
        #expect(composed == decomposed)
    }

    @Test func deriveKeyHandlesEmptyPassword() throws {
        let salt = Data(repeating: 2, count: 16)
        let key = try ConversationCrypto.deriveKey(password: "", salt: salt, iterations: testIterations)
        #expect(key.bitCount == 256)
    }

    @Test func deriveKeyRejectsBadParameters() {
        #expect(throws: (any Error).self) {
            _ = try ConversationCrypto.deriveKey(password: "pw", salt: Data(repeating: 1, count: 16), iterations: 0)
        }
        #expect(throws: (any Error).self) {
            _ = try ConversationCrypto.deriveKey(password: "pw", salt: Data(), iterations: testIterations)
        }
    }

    @Test func newKeyUsesRandom16ByteSalt() throws {
        let a = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let b = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        #expect(a.salt.count == 16)
        #expect(a.iterations == testIterations)
        #expect(a.salt != b.salt)
        #expect(a.key != b.key)
    }

    @Test func sealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let aad = Data("header".utf8)
        let plaintext = Data("hello world".utf8)
        let combined = try ConversationCrypto.seal(plaintext, key: key, aad: aad)
        #expect(combined.count == 12 + plaintext.count + 16)
        #expect(try ConversationCrypto.open(combined, key: key, aad: aad) == plaintext)
    }

    @Test func openWithWrongKeyOrAADIsWrongPassword() throws {
        let key = SymmetricKey(size: .bits256)
        let combined = try ConversationCrypto.seal(Data("x".utf8), key: key, aad: Data("a".utf8))
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationCrypto.open(combined, key: SymmetricKey(size: .bits256), aad: Data("a".utf8))
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationCrypto.open(combined, key: key, aad: Data("b".utf8))
        }
    }

    @Test func openTooShortIsCorrupt() {
        let key = SymmetricKey(size: .bits256)
        expectCorrupt { _ = try ConversationCrypto.open(Data([1, 2, 3]), key: key, aad: Data()) }
    }

    @Test func aadFormat() {
        let id = UUID(uuidString: "12345678-ABCD-4EF0-9123-456789ABCDEF")!
        let salt = Data([0, 1, 2, 3])
        let aad = ConversationCrypto.aad(id: id, iterations: 600_000, salt: salt)
        let expected = "parley.conversation|1|12345678-ABCD-4EF0-9123-456789ABCDEF|PBKDF2-HMAC-SHA256|600000|AAECAw==|AES-256-GCM"
        #expect(String(data: aad, encoding: .utf8) == expected)
    }
}

// MARK: - ConversationFile

@Suite("ConversationFile")
struct ConversationFileTests {
    @Test func fileNameIsUUIDOnly() {
        let id = UUID()
        #expect(ConversationFile.fileName(for: id) == "\(id.uuidString).json")
        #expect(ConversationFile.format == "parley.conversation")
        #expect(ConversationFile.version == 1)
    }

    @Test func plainRoundTrip() throws {
        let conversation = sampleConversation()
        let data = try ConversationFile.encode(conversation, encryption: nil)
        let decoded = try ConversationFile.decodePlain(data)
        #expect(decoded == conversation)

        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["format"] as? String == "parley.conversation")
        #expect(dict["version"] as? Int == 1)
        #expect(dict["encrypted"] as? Bool == false)
        #expect(dict["conversation"] is [String: Any])
        // iso8601 dates
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"2023-11-14T22:13:20Z\""))
    }

    @Test func encryptedRoundTripWithPassword() throws {
        let conversation = sampleConversation()
        let key = try ConversationCrypto.newKey(password: "correct horse", iterations: testIterations)
        let data = try ConversationFile.encode(conversation, encryption: key)

        let (decoded, derived) = try ConversationFile.decodeEncrypted(data, password: "correct horse")
        #expect(decoded == conversation)
        #expect(derived.salt == key.salt)
        #expect(derived.iterations == key.iterations)
        #expect(derived.key == key.key)

        // Fast path with an existing key.
        #expect(try ConversationFile.decodeEncrypted(data, key: key) == conversation)
    }

    @Test func encryptedLayout() throws {
        let conversation = sampleConversation()
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(conversation, encryption: key)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(dict.keys) == ["format", "version", "encrypted", "id", "kdf", "cipher", "payload"])
        #expect(dict["format"] as? String == "parley.conversation")
        #expect(dict["version"] as? Int == 1)
        #expect(dict["encrypted"] as? Bool == true)
        #expect(dict["id"] as? String == conversation.id.uuidString)
        #expect(dict["cipher"] as? String == "AES-256-GCM")
        let kdf = try #require(dict["kdf"] as? [String: Any])
        #expect(kdf["name"] as? String == "PBKDF2-HMAC-SHA256")
        #expect(kdf["iterations"] as? Int == testIterations)
        #expect(Data(base64Encoded: kdf["salt"] as? String ?? "") == key.salt)
        let payload = try #require(Data(base64Encoded: dict["payload"] as? String ?? ""))
        #expect(payload.count > 28)
    }

    @Test func wrongPasswordThrows() throws {
        let key = try ConversationCrypto.newKey(password: "right", iterations: testIterations)
        let data = try ConversationFile.encode(sampleConversation(), encryption: key)
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(data, password: "wrong")
        }
        let otherKey = try ConversationCrypto.newKey(password: "right", iterations: testIterations)
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(data, key: otherKey)
        }
    }

    @Test func tamperedPayloadFails() throws {
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(sampleConversation(), encryption: key)
        let tampered = try mutate(data) { dict in
            var payload = Data(base64Encoded: dict["payload"] as! String)!
            payload[payload.count / 2] ^= 0x01
            dict["payload"] = payload.base64EncodedString()
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, password: "pw")
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, key: key)
        }
    }

    @Test func tamperedIdFails() throws {
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(sampleConversation(), encryption: key)
        let tampered = try mutate(data) { $0["id"] = UUID().uuidString }
        // Same salt and iterations, so the derived key is identical: only the AAD differs.
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, password: "pw")
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, key: key)
        }
    }

    @Test func tamperedSaltFailsOnFastPath() throws {
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(sampleConversation(), encryption: key)
        let tampered = try mutate(data) { dict in
            var kdf = dict["kdf"] as! [String: Any]
            kdf["salt"] = Data(repeating: 0xAB, count: 16).base64EncodedString()
            dict["kdf"] = kdf
        }
        // The key is unchanged, so this only fails if the header salt is bound via AAD.
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, key: key)
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, password: "pw")
        }
    }

    @Test func tamperedIterationsFailsOnFastPath() throws {
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(sampleConversation(), encryption: key)
        let tampered = try mutate(data) { dict in
            var kdf = dict["kdf"] as! [String: Any]
            kdf["iterations"] = testIterations + 1
            dict["kdf"] = kdf
        }
        #expect(throws: ParleyError.wrongPassword) {
            _ = try ConversationFile.decodeEncrypted(tampered, key: key)
        }
    }

    @Test func noncesDifferBetweenSaves() throws {
        let conversation = sampleConversation()
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let a = try ConversationFile.encode(conversation, encryption: key)
        let b = try ConversationFile.encode(conversation, encryption: key)
        func payload(_ d: Data) throws -> Data {
            let dict = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
            return try #require(Data(base64Encoded: dict["payload"] as? String ?? ""))
        }
        let pa = try payload(a), pb = try payload(b)
        #expect(pa.prefix(12) != pb.prefix(12))
        #expect(pa != pb)
        #expect(try ConversationFile.decodeEncrypted(a, key: key) == conversation)
        #expect(try ConversationFile.decodeEncrypted(b, key: key) == conversation)
    }

    @Test func peekPlain() throws {
        let conversation = sampleConversation()
        let header = try ConversationFile.peek(try ConversationFile.encode(conversation, encryption: nil))
        #expect(header.id == conversation.id)
        #expect(header.isEncrypted == false)
        #expect(header.title == conversation.title)
        #expect(header.updatedAt == conversation.updatedAt)
        #expect(header.messageCount == conversation.messages.count)
    }

    @Test func peekEncryptedCarriesNoMetadata() throws {
        let conversation = sampleConversation(title: "Totally Private Title")
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(conversation, encryption: key)
        let header = try ConversationFile.peek(data)
        #expect(header.id == conversation.id)
        #expect(header.isEncrypted == true)
        #expect(header.title == nil)
        #expect(header.updatedAt == nil)
        #expect(header.messageCount == nil)

        // The raw bytes must not leak the title, message text, model, or file names.
        let raw = String(decoding: data, as: UTF8.self)
        for secret in ["Totally Private Title", "BLUEHERON", "launch codename", "mock-model", "notes.txt", "Be terse"] {
            #expect(!raw.contains(secret), "leaked \(secret)")
        }
    }

    @Test func forkInheritsKey() throws {
        let original = sampleConversation()
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        var fork = original.forked(through: 1)
        // forked() stamps Date(); round to whole seconds because .iso8601 drops fractions.
        fork.createdAt = date(fork.createdAt.timeIntervalSince1970.rounded(.down))
        fork.updatedAt = fork.createdAt
        let data = try ConversationFile.encode(fork, encryption: key)
        #expect(try ConversationFile.decodeEncrypted(data, key: key) == fork)
        #expect(try ConversationFile.decodeEncrypted(data, password: "pw").0 == fork)
    }

    @Test func notAConversationFile() {
        #expect(throws: ParleyError.notAConversationFile) {
            _ = try ConversationFile.peek(Data(#"{"hello":"world"}"#.utf8))
        }
        #expect(throws: ParleyError.notAConversationFile) {
            _ = try ConversationFile.peek(Data(#"{"format":"something.else","version":1}"#.utf8))
        }
        #expect(throws: ParleyError.notAConversationFile) {
            _ = try ConversationFile.peek(Data("[1,2,3]".utf8))
        }
    }

    @Test func unsupportedVersion() throws {
        let data = try ConversationFile.encode(sampleConversation(), encryption: nil)
        let v2 = try mutate(data) { $0["version"] = 2 }
        #expect(throws: ParleyError.unsupportedVersion(2)) { _ = try ConversationFile.peek(v2) }
        #expect(throws: ParleyError.unsupportedVersion(2)) { _ = try ConversationFile.decodePlain(v2) }

        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let enc = try ConversationFile.encode(sampleConversation(), encryption: key)
        let enc2 = try mutate(enc) { $0["version"] = 2 }
        #expect(throws: ParleyError.unsupportedVersion(2)) {
            _ = try ConversationFile.decodeEncrypted(enc2, key: key)
        }
    }

    @Test func malformedInputsAreCorrupt() throws {
        expectCorrupt { _ = try ConversationFile.peek(Data("not json at all".utf8)) }
        expectCorrupt { _ = try ConversationFile.peek(Data()) }

        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let enc = try ConversationFile.encode(sampleConversation(), encryption: key)

        let badPayload = try mutate(enc) { $0["payload"] = "!!!not base64!!!" }
        expectCorrupt { _ = try ConversationFile.peek(badPayload) }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(badPayload, key: key) }

        let shortPayload = try mutate(enc) { $0["payload"] = Data([1, 2, 3]).base64EncodedString() }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(shortPayload, key: key) }

        let badSalt = try mutate(enc) { dict in
            var kdf = dict["kdf"] as! [String: Any]
            kdf["salt"] = "%%%"
            dict["kdf"] = kdf
        }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(badSalt, key: key) }

        let badId = try mutate(enc) { $0["id"] = "not-a-uuid" }
        expectCorrupt { _ = try ConversationFile.peek(badId) }

        let badCipher = try mutate(enc) { $0["cipher"] = "ROT13" }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(badCipher, key: key) }

        let missingKdf = try mutate(enc) { $0.removeValue(forKey: "kdf") }
        expectCorrupt { _ = try ConversationFile.peek(missingKdf) }

        let plain = try ConversationFile.encode(sampleConversation(), encryption: nil)
        let badConversation = try mutate(plain) { $0["conversation"] = ["title": 5] }
        expectCorrupt { _ = try ConversationFile.decodePlain(badConversation) }

        let missingFlag = try mutate(plain) { $0.removeValue(forKey: "encrypted") }
        expectCorrupt { _ = try ConversationFile.peek(missingFlag) }
    }

    @Test func wrongKindDecodeIsCorrupt() throws {
        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let enc = try ConversationFile.encode(sampleConversation(), encryption: key)
        let plain = try ConversationFile.encode(sampleConversation(), encryption: nil)
        expectCorrupt { _ = try ConversationFile.decodePlain(enc) }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(plain, key: key) }
        expectCorrupt { _ = try ConversationFile.decodeEncrypted(plain, password: "pw") }
    }

    @Test func writeCreatesDirectoriesAndPermissions() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirA = root.appendingPathComponent("a", isDirectory: true)
        let dirB = dirA.appendingPathComponent("b", isDirectory: true)
        let dirC = dirB.appendingPathComponent("c", isDirectory: true)
        let conversation = sampleConversation()
        let url = dirC.appendingPathComponent(ConversationFile.fileName(for: conversation.id))

        let data = try ConversationFile.encode(conversation, encryption: nil)
        try ConversationFile.write(data, to: url)

        #expect(try Data(contentsOf: url) == data)
        #expect(try posixMode(url) == 0o600)
        #expect(try posixMode(dirA) == 0o700)
        #expect(try posixMode(dirB) == 0o700)
        #expect(try posixMode(dirC) == 0o700)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dirC.path) == [url.lastPathComponent])
    }

    @Test func writeOverwritesAndTightensPermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existingMode = try posixMode(dir)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("old contents".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let conversation = sampleConversation()
        let data = try ConversationFile.encode(conversation, encryption: key)
        try ConversationFile.write(data, to: url)

        #expect(try posixMode(url) == 0o600)
        #expect(try ConversationFile.decodeEncrypted(try Data(contentsOf: url), key: key) == conversation)
        // An existing directory's permissions are left alone.
        #expect(try posixMode(dir) == existingMode)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [url.lastPathComponent])
    }

    @Test func writeThroughSymlinkReplacesTargetNotLink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let targetDir = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = targetDir.appendingPathComponent("conv.json")
        let link = dir.appendingPathComponent("link.json")
        let conversation = sampleConversation()
        try ConversationFile.encode(conversation, encryption: nil).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let key = try ConversationCrypto.newKey(password: "pw", iterations: testIterations)
        let data = try ConversationFile.encode(conversation, encryption: key)
        try ConversationFile.write(data, to: link)

        // The link is still a link, and the real file now holds the ciphertext.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        let onDisk = try Data(contentsOf: target)
        #expect(onDisk == data)
        #expect(!String(decoding: onDisk, as: UTF8.self).contains("Secret project plans"))
        #expect(try posixMode(target) == 0o600)
        // No temp file left in either directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: targetDir.path) == ["conv.json"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["real", "link.json"])
    }

    @Test func writeRefusesDanglingSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("missing.json").path)
        #expect(throws: (any Error).self) {
            try ConversationFile.write(Data("x".utf8), to: link)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.json").path))
    }

    @Test func writeFailsWhenParentIsAFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) {
            try ConversationFile.write(Data("x".utf8), to: blocker.appendingPathComponent("x.json"))
        }
    }
}

// MARK: - Conversation truncate / forked

@Suite("Conversation boundaries")
struct ConversationBoundaryTests {
    private func numbered(_ n: Int) -> Conversation {
        Conversation(
            title: "Chat",
            createdAt: date(1_000),
            updatedAt: date(1_000),
            messages: (0..<n).map { i in
                Message(role: i.isMultiple(of: 2) ? .user : .assistant, content: "m\(i)", createdAt: date(Double(2_000 + i)))
            }
        )
    }

    @Test func truncateKeepsThroughIndex() {
        var c = numbered(4)
        let ids = c.messages.map(\.id)
        c.truncate(keepingThrough: 1)
        #expect(c.messages.map(\.id) == Array(ids.prefix(2)))
        #expect(c.updatedAt > date(1_000))
    }

    @Test func truncateBoundaries() {
        var all = numbered(4)
        all.truncate(keepingThrough: 3)
        #expect(all.messages.count == 4)

        var none = numbered(4)
        none.truncate(keepingThrough: -1)
        #expect(none.messages.isEmpty)

        var first = numbered(4)
        first.truncate(keepingThrough: 0)
        #expect(first.messages.map(\.content) == ["m0"])

        // Out of range: no-op, and updatedAt untouched.
        var high = numbered(4)
        high.truncate(keepingThrough: 4)
        #expect(high.messages.count == 4)
        #expect(high.updatedAt == date(1_000))

        var low = numbered(4)
        low.truncate(keepingThrough: -2)
        #expect(low.messages.count == 4)
        #expect(low.updatedAt == date(1_000))

        var empty = numbered(0)
        empty.truncate(keepingThrough: 0)
        #expect(empty.messages.isEmpty)
        empty.truncate(keepingThrough: -1)
        #expect(empty.messages.isEmpty)
    }

    @Test func forkedThroughIndex() {
        let c = numbered(4)
        let f = c.forked(through: 1)
        #expect(f.id != c.id)
        #expect(f.title == "Chat (fork)")
        #expect(f.messages.map(\.id) == Array(c.messages.prefix(2)).map(\.id))
        #expect(f.forkedFrom == ForkOrigin(conversationID: c.id, messageID: c.messages[1].id))
        #expect(f.settings == c.settings)
        // The original is unchanged.
        #expect(c.messages.count == 4)
    }

    @Test func forkedBoundaries() {
        let c = numbered(4)

        let first = c.forked(through: 0)
        #expect(first.messages.map(\.id) == [c.messages[0].id])
        #expect(first.forkedFrom?.messageID == c.messages[0].id)

        let last = c.forked(through: 3)
        #expect(last.messages.count == 4)
        #expect(last.forkedFrom?.messageID == c.messages[3].id)

        let clampedHigh = c.forked(through: 99)
        #expect(clampedHigh.messages.count == 4)
        #expect(clampedHigh.forkedFrom?.messageID == c.messages[3].id)

        let none = c.forked(through: -1)
        #expect(none.messages.isEmpty)
        #expect(none.forkedFrom == nil)

        let clampedLow = c.forked(through: -5)
        #expect(clampedLow.messages.isEmpty)
        #expect(clampedLow.forkedFrom == nil)

        let fromEmpty = numbered(0).forked(through: 0)
        #expect(fromEmpty.messages.isEmpty)
        #expect(fromEmpty.forkedFrom == nil)
    }
}

// MARK: - Keychain

/// Keychain access can be unavailable in headless/CI sessions (no unlocked login keychain,
/// no UI for prompts). Probe once with a separate service and skip the test if so.
private enum KeychainProbe {
    static let skipStatuses: Set<OSStatus> = [
        errSecInteractionNotAllowed, // -25308
        errSecAuthFailed,            // -25293
        errSecNotAvailable,          // -25291
        errSecNoSuchKeychain,        // -25294
        errSecMissingEntitlement,    // -34018
    ]

    static let available: Bool = {
        let service = "local.parley.chat.test-probe"
        let account = UUID().uuidString
        defer { try? KeychainStore.deleteValue(service: service, account: account) }
        do {
            try KeychainStore.setValue("probe", service: service, account: account)
            return true
        } catch ParleyError.keychain(let status) where skipStatuses.contains(status) {
            return false
        } catch {
            // Unexpected failure: let the real test run and report it.
            return true
        }
    }()
}

@Suite("Keychain")
struct KeychainTests {
    @Test(.enabled(if: KeychainProbe.available, "Keychain is not available in this environment"))
    func setReadDelete() throws {
        let provider = UUID()
        defer { try? KeychainStore.deleteAPIKey(for: provider) }

        #expect(try KeychainStore.apiKey(for: provider) == nil)

        try KeychainStore.setAPIKey("sk-test-123", for: provider)
        #expect(try KeychainStore.apiKey(for: provider) == "sk-test-123")

        // Upsert replaces the value.
        try KeychainStore.setAPIKey("sk-test-456", for: provider)
        #expect(try KeychainStore.apiKey(for: provider) == "sk-test-456")

        try KeychainStore.deleteAPIKey(for: provider)
        #expect(try KeychainStore.apiKey(for: provider) == nil)

        // Deleting again is not an error.
        try KeychainStore.deleteAPIKey(for: provider)

        // Empty string deletes.
        try KeychainStore.setAPIKey("sk-temp", for: provider)
        try KeychainStore.setAPIKey("", for: provider)
        #expect(try KeychainStore.apiKey(for: provider) == nil)
    }

    @Test func serviceName() {
        #expect(KeychainStore.service == "local.parley.chat.apikey")
    }
}
