import AppKit
import Foundation
import Observation
import ParleyCore

/// Root state: settings, the conversation library, open sessions and selection.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let settings: AppSettings
    private(set) var entries: [LibraryEntry] = []
    private(set) var sessions: [UUID: ConversationSession] = [:]
    var selection: UUID?

    var isScanning = false
    /// Per-entry load errors (e.g. damaged file).
    var loadErrors: [UUID: String] = [:]
    /// Model lists fetched from providers, memory only.
    var modelsByProvider: [UUID: [String]] = [:]
    var modelFetchError: String?

    // UI triggers
    var showNewChatSheet = false
    /// One-off informational alert.
    var notice: Notice?

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
    }

    // MARK: - Library

    func entry(id: UUID?) -> LibraryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func session(for id: UUID?) -> ConversationSession? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// Display title. Encrypted conversations only show a title while unlocked in memory.
    func displayTitle(for entry: LibraryEntry) -> String? {
        if let session = sessions[entry.id] { return session.conversation.title }
        if entry.isEncrypted { return nil }
        return entry.title ?? "Untitled"
    }

    func sortDate(for entry: LibraryEntry) -> Date {
        sessions[entry.id]?.conversation.updatedAt ?? entry.updatedAt
    }

    var sortedEntries: [LibraryEntry] {
        entries.sorted { sortDate(for: $0) > sortDate(for: $1) }
    }

    func reloadLibrary() {
        let dir = settings.defaultDirectoryURL
        let extra = settings.extraConversationPaths
        let hidden = Set(settings.hiddenConversationPaths)
        isScanning = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(directory: dir, extraPaths: extra, hiddenPaths: hidden)
            }.value
            self.mergeScanned(scanned)
            self.isScanning = false
        }
    }

    private func mergeScanned(_ scanned: [LibraryEntry]) {
        var result: [LibraryEntry] = []
        var seen = Set<UUID>()
        for var e in scanned {
            // An open session is the source of truth for its entry.
            if let s = sessions[e.id] {
                e.url = s.fileURL
                e.isEncrypted = s.isEncrypted
                e.title = s.isEncrypted ? nil : s.conversation.title
            }
            result.append(e)
            seen.insert(e.id)
        }
        // Keep entries for open sessions whose file isn't visible to the scan.
        for e in entries where !seen.contains(e.id) && sessions[e.id] != nil {
            result.append(e)
        }
        entries = result
        if let sel = selection, !entries.contains(where: { $0.id == sel }) {
            selection = nil
        }
    }

    private func upsertEntry(_ entry: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Keeps the library entry in sync with what was just written. Never stores
    /// the title of an encrypted conversation.
    private func syncEntry(from session: ConversationSession) {
        let entry = LibraryEntry(
            id: session.id,
            url: session.fileURL,
            isEncrypted: session.isEncrypted,
            title: session.isEncrypted ? nil : session.conversation.title,
            updatedAt: session.isEncrypted ? Date() : session.conversation.updatedAt
        )
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            if entries[i] != entry { entries[i] = entry }
        } else {
            entries.append(entry)
        }
    }

    private func register(_ session: ConversationSession) {
        session.didEnqueueSave = { [weak self] s in
            self?.syncEntry(from: s)
        }
        sessions[session.id] = session
    }

    // MARK: - Opening

    /// Loads a plain conversation from disk (off the main thread).
    @discardableResult
    func loadPlain(_ entry: LibraryEntry) async -> ConversationSession? {
        if let s = sessions[entry.id] { return s }
        guard !entry.isEncrypted else { return nil }
        let url = entry.url
        do {
            let conversation = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try ConversationFile.decodePlain(data)
            }.value
            if let s = sessions[entry.id] { return s }
            let session = ConversationSession(conversation: conversation, fileURL: url, encryption: nil)
            register(session)
            loadErrors[entry.id] = nil
            return session
        } catch {
            loadErrors[entry.id] = error.localizedDescription
            return nil
        }
    }

    /// Decrypts an encrypted conversation in memory. Key derivation runs off the main thread.
    func unlock(_ entry: LibraryEntry, password: String) async throws {
        if sessions[entry.id] != nil { return }
        let url = entry.url
        let (conversation, key) = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try ConversationFile.decodeEncrypted(data, password: password)
        }.value
        if sessions[entry.id] != nil { return }
        let session = ConversationSession(conversation: conversation, fileURL: url, encryption: key)
        register(session)
    }

    /// Flush, then drop the decrypted conversation and key from memory. If the final save
    /// fails, the conversation stays unlocked (so nothing is lost) and a notice explains why.
    func lock(_ id: UUID) {
        if let error = lockSession(id) {
            notice = Notice(title: "Could not lock", message: "The conversation could not be saved, so it was left unlocked to keep your changes. \(error)")
        }
    }

    func lockAll() {
        var failures: [String] = []
        for (id, s) in sessions where s.isEncrypted {
            if let error = lockSession(id) { failures.append(error) }
        }
        if !failures.isEmpty {
            notice = Notice(
                title: "Could not lock",
                message: "\(failures.count) conversation\(failures.count == 1 ? "" : "s") could not be saved and stayed unlocked to keep your changes. \(failures[0])"
            )
        }
    }

    /// Returns the save error, or nil once the session is locked.
    private func lockSession(_ id: UUID) -> String? {
        guard let session = sessions[id], session.isEncrypted else { return nil }
        if let error = session.close(saving: true) { return error }
        sessions[id] = nil
        return nil
    }

    // MARK: - Creating

    func createConversation(title: String, directory: URL, password: String?) async throws {
        var settingsValue = ConversationSettings(providerID: settings.defaultProvider?.id)
        settingsValue.model = settings.defaultProvider?.defaultModel ?? ""
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = Conversation(
            title: trimmedTitle.isEmpty ? ConversationSession.defaultTitle : trimmedTitle,
            settings: settingsValue
        )
        var key: EncryptionKey?
        if let password {
            key = try await Task.detached(priority: .userInitiated) {
                try ConversationCrypto.newKey(password: password)
            }.value
        }
        let url = directory.appendingPathComponent(ConversationFile.fileName(for: conversation.id))
        let session = ConversationSession(conversation: conversation, fileURL: url, encryption: key)
        session.markUnsaved()
        // Write first, so a folder that cannot be written fails here (shown in the sheet)
        // instead of leaving a library entry for a file that never existed.
        if let error = session.flushSync() {
            throw SaveFailure(message: error)
        }
        register(session)
        syncEntry(from: session)
        settings.rememberConversationFile(url)
        selection = session.id
    }

    /// Fork through message `index`: same directory, same encryption key.
    func fork(_ session: ConversationSession, through index: Int) {
        guard !session.isStreaming else { return }
        let forked = session.conversation.forked(through: index)
        let dir = session.fileURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent(ConversationFile.fileName(for: forked.id))
        let newSession = ConversationSession(conversation: forked, fileURL: url, encryption: session.encryption)
        newSession.markUnsaved()
        if let error = newSession.flushSync() {
            notice = Notice(title: "Could not fork", message: "The new conversation could not be saved. \(error)")
            return
        }
        register(newSession)
        syncEntry(from: newSession)
        settings.rememberConversationFile(url)
        selection = newSession.id
    }

    // MARK: - Encryption management

    static let encryptedOverwriteNotice = Notice(
        title: "Conversation encrypted",
        message: "The previous unencrypted file was overwritten in place. On SSDs/APFS this is not a secure erase; older copies may exist in backups or snapshots."
    )

    /// Encrypts (or re-keys) an open conversation and overwrites its file in place.
    /// Returns true when a previously plain file was encrypted (the caller shows
    /// `encryptedOverwriteNotice` once its sheet is dismissed).
    @discardableResult
    func setPassword(for session: ConversationSession, password: String) async throws -> Bool {
        let wasEncrypted = session.isEncrypted
        let key = try await Task.detached(priority: .userInitiated) {
            try ConversationCrypto.newKey(password: password)
        }.value
        let previous = session.encryption
        session.encryption = key
        if let error = session.flushSync() {
            // Memory must keep matching what is on disk (the old key, or plain).
            session.encryption = previous
            throw SaveFailure(message: error)
        }
        return !wasEncrypted
    }

    func removeEncryption(from session: ConversationSession) {
        let previous = session.encryption
        session.encryption = nil
        if let error = session.flushSync() {
            session.encryption = previous
            notice = Notice(title: "Could not remove encryption", message: "The file could not be written and is still encrypted. \(error)")
        }
    }

    // MARK: - File management

    func openConversationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose Parley conversation files"
        guard panel.runModal() == .OK else { return }
        var firstID: UUID?
        var failures: [String] = []
        for url in panel.urls {
            if let entry = LibraryScanner.entry(for: url) {
                if let existing = entries.first(where: { $0.id == entry.id }) {
                    firstID = firstID ?? existing.id
                    continue
                }
                settings.rememberConversationFile(url)
                upsertEntry(entry)
                firstID = firstID ?? entry.id
            } else {
                failures.append(url.lastPathComponent)
            }
        }
        if let firstID { selection = firstID }
        if !failures.isEmpty {
            notice = Notice(title: "Could not open", message: "Not a Parley conversation: \(failures.joined(separator: ", "))")
        }
    }

    func revealInFinder(_ entry: LibraryEntry) {
        let url = sessions[entry.id]?.fileURL ?? entry.url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeFromList(_ entry: LibraryEntry) {
        if let s = sessions[entry.id] {
            if let error = s.close(saving: true) {
                notice = Notice(title: "Could not remove from list", message: "The conversation could not be saved, so it was kept open to keep your changes. \(error)")
                return
            }
            sessions[entry.id] = nil
        }
        settings.forgetConversationFile(entry.url, hide: true)
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id { selection = nil }
    }

    /// Moves the file to the Trash (not a permanent delete).
    func moveToTrash(_ entry: LibraryEntry) {
        let url = sessions[entry.id]?.fileURL ?? entry.url
        if let s = sessions[entry.id] {
            s.close(saving: false)
            sessions[entry.id] = nil
        }
        // Make sure no queued write recreates the file after it is trashed.
        ConversationWriter.flush()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            settings.forgetConversationFile(url, hide: false)
            entries.removeAll { $0.id == entry.id }
            if selection == entry.id { selection = nil }
        } catch {
            notice = Notice(title: "Could not move to Trash", message: error.localizedDescription)
        }
    }

    /// Changes the default folder. Conversations already listed from the old folder
    /// stay in the library (their paths move to the extra paths list).
    func changeDefaultDirectory(to url: URL) {
        for entry in entries {
            let fileURL = sessions[entry.id]?.fileURL ?? entry.url
            if settings.isInDefaultDirectory(fileURL) {
                let path = AppSettings.normalizedPath(fileURL)
                if !settings.extraConversationPaths.contains(path) {
                    settings.extraConversationPaths.append(path)
                }
            }
        }
        settings.defaultDirectoryPath = url.path
        reloadLibrary()
    }

    // MARK: - Models

    func refreshModels(for provider: Provider) async {
        modelFetchError = nil
        do {
            let key = try KeychainStore.apiKey(for: provider.id)
            let client = try ChatClient(baseURL: provider.baseURL, apiKey: key)
            let models = try await client.listModels()
            modelsByProvider[provider.id] = models
        } catch {
            modelFetchError = error.localizedDescription
        }
    }

    // MARK: - Lifecycle

    /// Before quitting: writes every open session that has unsaved changes, without closing
    /// anything (the user may still cancel the quit). Returns the failures.
    func saveAllBeforeQuit() -> (count: Int, firstError: String?) {
        var failures: [String] = []
        for session in sessions.values {
            if let error = session.flushSync(onlyIfChanged: true) { failures.append(error) }
        }
        ConversationWriter.flush()
        return (failures.count, failures.first)
    }

    /// Synchronously writes every open session and stops streams (quit is happening).
    func flushAllSync() {
        for session in sessions.values {
            session.close(saving: true)
        }
        ConversationWriter.flush()
    }
}

/// A conversation file could not be written. The message never contains conversation content.
struct SaveFailure: LocalizedError {
    let message: String
    var errorDescription: String? { "Could not save the conversation: \(message)" }
}
