import Foundation
import Testing
@testable import Parley
@testable import ParleyCore

// Regression tests for app-layer fixes (staged edits, library scan races, password race,
// reply-finished hook). Same isolation as AppFlowTests.

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python3Path)))
@MainActor
struct AppRegressionTests {
    // Regenerate / rollback during a staged edit cancel the edit cleanly: the old draft comes back.
    @Test func regenerateAndRollbackCancelStagedEdit() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("first", in: session)
            try await fx.send("second", in: session)

            session.draftText = "half-typed"
            session.beginEdit(messageAt: 2)
            #expect(session.draftText == "second")
            session.regenerate(messageAt: 3, settings: fx.settings)
            try await fx.waitForReply(session)
            #expect(session.pendingEditMessageID == nil)
            #expect(session.draftText == "half-typed")

            session.draftText = ""
            session.beginEdit(messageAt: 0)
            session.rollback(toMessageAt: 1)
            #expect(session.pendingEditMessageID == nil)
            #expect(session.draftText.isEmpty)
            #expect(session.draftAttachments.isEmpty)
        }
    }

    // A reply that ends with no ChatView attached still runs replyFinished (vision refusal learned).
    @Test func replyFinishedRunsWithoutAView() async throws {
        try await withFixture(model: "strata-novision", flavor: "strata-share") { fx in
            fx.state.followsReplyEnd = true
            await fx.state.refreshContextInfo(provider: fx.provider, model: "strata-novision")
            let session = try await fx.create()
            let image = Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50]))
            session.send(text: "look", attachments: [image], settings: fx.settings)
            try await fx.waitForReply(session)
            #expect(fx.state.contextInfo(provider: fx.provider, model: "strata-novision")?.acceptsImages == false)
        }
    }

    // A scan result must not drop entries added, or bring back entries removed, while it ran.
    @Test func scanMergeKeepsNewerChanges() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            let existing = try #require(fx.state.entry(id: session.id))
            let before = Set(fx.state.entries.map(\.id))

            let added = LibraryEntry(id: UUID(), url: fx.defaultDir.appendingPathComponent("added.json"),
                                     isEncrypted: true, title: nil, updatedAt: Date())
            fx.state.upsertEntry(added)
            fx.state.selection = added.id
            fx.state.mergeScanned([existing], entriesBefore: before)
            #expect(fx.state.entry(id: added.id) != nil)
            #expect(fx.state.selection == added.id)

            // Removed while the scan ran: the stale scan still lists it.
            fx.state.removeFromList(existing)
            fx.state.mergeScanned([existing], entriesBefore: before)
            #expect(fx.state.entry(id: existing.id) == nil)
        }
    }

    // Closed during key derivation: the password change is reported as failed, not done.
    @Test func setPasswordFailsWhenSessionClosedMeanwhile() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            try await fx.send("hello", in: session)
            fx.state.removeFromList(try #require(fx.state.entry(id: session.id)))
            await #expect(throws: SaveFailure.self) {
                try await fx.state.setPassword(for: session, password: "pw")
            }
            #expect(!session.isEncrypted)
        }
    }

    // Dropping several files: a later successful import does not clear an earlier error.
    @Test func importKeepsEarlierError() async throws {
        try await withFixture { fx in
            let session = try await fx.create()
            let good = fx.root.appendingPathComponent("good.txt")
            try "hi".write(to: good, atomically: true, encoding: .utf8)
            let missing = fx.root.appendingPathComponent("missing.bin")
            AttachmentImport.importFiles([missing], into: session)
            #expect(await waitUntil { session.composerError != nil })
            AttachmentImport.importFiles([good], into: session)
            #expect(await waitUntil { session.draftAttachments.count == 1 })
            #expect(session.composerError != nil)
        }
    }
}
