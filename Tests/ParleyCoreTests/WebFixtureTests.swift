import Foundation
import Testing
@testable import ParleyCore

// Files written by Parley Web (tools/web_fixtures.mjs) must open in Parley with the app's own code,
// plain and encrypted, with everything in them intact. Runs only with PARLEY_WEB_FIXTURES set to the
// folder the script wrote (tools/test_web.sh does both steps).

private let fixtureFolder = ProcessInfo.processInfo.environment["PARLEY_WEB_FIXTURES"]
/// The password tools/web_fixtures.mjs encrypts with (its PASSWORD).
private let webFixturePassword = "correct horse"

private func read(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: fixtureFolder!).appendingPathComponent(name))
}

private func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    d.dataDecodingStrategy = .base64
    return d
}

@Suite(.enabled(if: fixtureFolder != nil)) struct WebFixtureTests {
    @Test func readWebFixtures() throws {
        let expected = try decoder().decode(Conversation.self, from: try read("expected.json"))
        #expect(!expected.messages.isEmpty)

        // Plain: the envelope, then the conversation as the app reads any file.
        let header = try ConversationFile.peek(try read("plain.json"))
        #expect(!header.isEncrypted && header.id == expected.id)
        let plain = try ConversationFile.decodePlain(try read("plain.json"))
        #expect(plain == expected)

        // Encrypted: Parley's own decryption with the password.
        let sealed = try read("encrypted.json")
        #expect(try ConversationFile.peek(sealed).isEncrypted)
        let text = String(decoding: sealed, as: UTF8.self)
        for secret in expected.messages.map(\.content).filter({ $0.count > 6 }) + [expected.title] {
            #expect(!text.contains(secret), "no message text or title in the clear")
        }
        let (decrypted, key) = try ConversationFile.decodeEncrypted(sealed, password: webFixturePassword)
        #expect(decrypted == expected)
        #expect(throws: (any Error).self) { try ConversationFile.decodeEncrypted(sealed, password: "wrong") }

        // What the fixture is meant to cover is really in it.
        let messages = decrypted.messages
        #expect(messages.contains { $0.role == .assistant && ($0.reasoning ?? "").isEmpty == false && $0.usage != nil })
        #expect(messages.flatMap(\.attachments).contains { $0.kind == .image && $0.data != nil })
        #expect(messages.flatMap(\.attachments).contains { $0.kind == .text && $0.text != nil })
        #expect(decrypted.compaction != nil && decrypted.compactionBoundary != nil)
        #expect(decrypted.settings.providerID != nil, "a server the Mac app does not know")

        // Saving it again in the app and reading it back changes nothing.
        let again = try ConversationFile.decodeEncrypted(try ConversationFile.encode(decrypted, encryption: key), key: key)
        #expect(again == expected)
    }
}
