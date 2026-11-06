import Foundation
import Testing
@testable import ParleyCore

// Old files keep decoding, new files stay readable by old versions, and encryption covers tool data.

private func sampleReply() -> Message {
    var reply = Message(role: .assistant, content: "Done.")
    reply.toolRounds = [ToolRound(content: "Looking.", calls: [
        ToolCallRecord(id: "call_1", name: "srv__read", arguments: #"{"path":"/secret/plan.txt"}"#, serverID: UUID(), serverName: "srv",
                       toolName: "read", startedAt: Date(timeIntervalSince1970: 100),
                       result: ToolCallResult(status: .completed, text: "the launch code is 1234", duration: 0.5)),
    ], usage: TokenUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12))]
    reply.toolNotes = [ToolNote(kind: ToolNote.roundLimit, detail: "10")]
    reply.toolDefinitionTokens = 120
    return reply
}

/// Today's Message without the tool fields, as an older Parley decodes it.
private struct LegacyMessage: Codable {
    var id: UUID
    var role: Role
    var content: String
    var reasoning: String?
    var attachments: [ParleyCore.Attachment]
    var createdAt: Date
    var isComplete: Bool
}

@Suite struct ToolStorageTests {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func aFileWrittenBeforeToolsDecodes() throws {
        let id = UUID()
        let json = """
        {"format":"parley.conversation","version":1,"encrypted":false,"conversation":{
          "id":"\(id.uuidString)","title":"Old","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
          "settings":{"model":"m","systemPrompt":""},
          "messages":[{"id":"\(UUID().uuidString)","role":"assistant","content":"hi","attachments":[],
                       "createdAt":"2026-01-01T00:00:00Z","isComplete":true}]}}
        """
        let conversation = try ConversationFile.decodePlain(Data(json.utf8))
        #expect(conversation.messages[0].toolRounds == nil)
        #expect(conversation.settings.mcpServerIDs == nil)
        let rewritten = String(decoding: try ConversationFile.encode(conversation, encryption: nil), as: UTF8.self)
        #expect(!rewritten.contains("toolRounds"))
        #expect(!rewritten.contains("mcpServerIDs"))
    }

    @Test func roundsSurviveARoundTrip() throws {
        var conversation = Conversation(messages: [Message(role: .user, content: "go"), sampleReply()])
        conversation.settings.mcpServerIDs = [UUID()]
        let decoded = try ConversationFile.decodePlain(try ConversationFile.encode(conversation, encryption: nil))
        // Dates lose their fractions in ISO 8601; everything about tools must not lose anything.
        #expect(decoded.messages[1].toolRounds == conversation.messages[1].toolRounds)
        #expect(decoded.messages[1].toolNotes == conversation.messages[1].toolNotes)
        #expect(decoded.messages[1].toolDefinitionTokens == 120)
        #expect(decoded.settings.mcpServerIDs == conversation.settings.mcpServerIDs)
    }

    @Test func anOlderVersionStillReadsTheFile() throws {
        let data = try ConversationFile.encode(Conversation(messages: [sampleReply()]), encryption: nil)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require((root["conversation"] as? [String: Any])?["messages"])
        let encoded = try JSONSerialization.data(withJSONObject: messages)
        let legacy = try decoder().decode([LegacyMessage].self, from: encoded)
        #expect(legacy.first?.content == "Done.")
    }

    @Test func aStatusFromALaterVersionDecodes() throws {
        let json = #"{"status":"somethingNew","text":"x"}"#
        let result = try JSONDecoder().decode(ToolCallResult.self, from: Data(json.utf8))
        #expect(result.status == "somethingNew")
    }

    @Test func encryptedFilesHoldNoToolTextInTheClear() throws {
        let key = try ConversationCrypto.newKey(password: "test-password", iterations: 1000)
        let data = try ConversationFile.encode(Conversation(messages: [sampleReply()]), encryption: key)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["launch code", "plan.txt", "srv__read", "toolRounds"] {
            #expect(!text.contains(secret))
        }
        let decoded = try ConversationFile.decodeEncrypted(data, key: key)
        #expect(decoded.messages[0].toolRounds?[0].calls[0].result?.text == "the launch code is 1234")
    }

    @Test func truncateAndForkKeepRoundsWhole() {
        var conversation = Conversation(messages: [Message(role: .user, content: "go"), sampleReply(), Message(role: .user, content: "more")])
        let fork = conversation.forked(through: 1)
        #expect(fork.messages[1].toolRounds?.count == 1)
        #expect(fork.settings.mcpServerIDs == conversation.settings.mcpServerIDs)
        conversation.truncate(keepingThrough: 1)
        #expect(conversation.messages.last?.toolRounds?[0].calls[0].result != nil)
    }
}
