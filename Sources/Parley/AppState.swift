import AppKit
import Foundation
import Observation
import ParleyCore

/// Root state: settings, the conversation library, open sessions and selection.
@MainActor
@Observable
final class AppState {
    static let shared: AppState = {
        #if DEBUG
        // Debug snapshot mode (PARLEY_SNAPSHOT_DIR): isolated settings, temp folder, sample data.
        if let settings = SnapshotHarness.isolatedSettingsIfActive() {
            return AppState(settings: settings)
        }
        #endif
        return AppState()
    }()

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
    /// Per-provider model-list state (memory only).
    var modelLoadState: [UUID: ModelLoadState] = [:]
    /// The base URL each provider's model list was fetched from, so an edited URL refetches.
    @ObservationIgnored private var modelsFetchedFrom: [UUID: String] = [:]

    enum ModelLoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    /// What each provider's server said about a model's context window (memory only). A probe
    /// that learned nothing (server not running, 401, timeout) is not cached, so a later one retries.
    private(set) var contextInfo: [ContextKey: ModelContextInfo] = [:]
    /// Probes and reloads in flight.
    private(set) var contextProbing: Set<ContextKey> = []
    /// AppState owns each probe, so a view's cancelled .task does not lose its result, and a
    /// second caller waits for the first instead of returning empty-handed.
    @ObservationIgnored private var probeTasks: [ContextKey: Task<Void, Never>] = [:]
    /// When a probe last learned nothing: non-forced retries wait `emptyProbeRetryInterval`.
    @ObservationIgnored private var emptyProbeAt: [ContextKey: Date] = [:]
    static let emptyProbeRetryInterval: TimeInterval = 30
    /// The running reload, or how the last one ended until the context popover has shown it.
    private(set) var reloadStates: [ContextKey: ReloadState] = [:]
    /// Server-side reloads in flight, by base URL and model key, whichever provider or
    /// conversation started them: a second load of a model that is not loaded yet would add
    /// another copy on the server.
    @ObservationIgnored private var reloadsInFlight: Set<String> = []

    enum ReloadState: Equatable {
        case running(contextLength: Int)
        case failed(String)
        /// `note` when the outcome differs from what was asked for.
        case finished(note: String?)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Cache key: the provider's base URL is part of it, so editing the URL re-probes.
    struct ContextKey: Hashable {
        let providerID: UUID
        let baseURL: String
        let model: String

        init(provider: Provider, model: String) {
            providerID = provider.id
            baseURL = provider.baseURL
            self.model = model
        }
    }

    /// Requests from menu commands that the sidebar carries out (it owns the sheets and dialogs).
    var sidebarRequest: SidebarRequest?
    /// Set by the Conversation menu: ChatView opens its settings popover for this conversation.
    var conversationSettingsRequest: UUID?

    enum SidebarRequest: Equatable {
        case rename(UUID), encrypt(UUID), changePassword(UUID), removeEncryption(UUID), moveToTrash(UUID)
    }

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
        // What the server said about the model (kind, limits) shapes the request (Strata fields).
        session.serverInfo = { [weak self] provider, model in
            self?.contextInfo(provider: provider, model: model)
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

    /// Fetches the model list from this one provider (only its configured endpoint is contacted).
    func refreshModels(for provider: Provider) async {
        modelFetchError = nil
        modelLoadState[provider.id] = .loading
        let baseURL = provider.baseURL
        do {
            let key = try KeychainStore.apiKey(for: provider.id)
            let client = try ChatClient(baseURL: baseURL, apiKey: key)
            let models = try await client.listModels()
            modelsByProvider[provider.id] = models
            modelsFetchedFrom[provider.id] = baseURL
            modelLoadState[provider.id] = .loaded
        } catch {
            modelFetchError = error.localizedDescription
            modelsFetchedFrom[provider.id] = baseURL
            modelLoadState[provider.id] = .failed(error.localizedDescription)
        }
    }

    /// Loads the model list once per provider and base URL; later calls reuse it.
    func loadModelsIfNeeded(for provider: Provider) async {
        switch modelLoadState[provider.id] {
        case .loading:
            return
        case .loaded, .failed:
            if modelsFetchedFrom[provider.id] == provider.baseURL { return }
        case .idle, .none:
            break
        }
        await refreshModels(for: provider)
    }

    /// Records a list fetched elsewhere (Settings > Test Connection).
    func storeModels(_ models: [String], for provider: Provider) {
        modelsByProvider[provider.id] = models
        modelsFetchedFrom[provider.id] = provider.baseURL
        modelLoadState[provider.id] = .loaded
    }

    // MARK: - Context length

    func contextInfo(provider: Provider, model: String) -> ModelContextInfo? {
        contextInfo[ContextKey(provider: provider, model: model)]
    }

    func isProbingContext(provider: Provider, model: String) -> Bool {
        contextProbing.contains(ContextKey(provider: provider, model: model))
    }

    /// Asks this provider's own server about the model's context length (read-only GETs; see
    /// ChatClient.fetchModelInfo). Cached per provider, base URL and model; `force` re-reads.
    func refreshContextInfo(provider: Provider, model: String, force: Bool = false) async {
        let key = ContextKey(provider: provider, model: model)
        guard !model.isEmpty else { return }
        if let running = probeTasks[key] {
            await running.value
            return
        }
        // A reload re-reads the server itself when it is done.
        if reloadStates[key]?.isRunning == true { return }
        if !force {
            if contextInfo[key] != nil { return }
            if let at = emptyProbeAt[key], Date().timeIntervalSince(at) < Self.emptyProbeRetryInterval { return }
        }
        guard let client = try? ChatClient(baseURL: provider.baseURL, apiKey: try? KeychainStore.apiKey(for: provider.id)) else { return }
        contextProbing.insert(key)
        let task = Task { [weak self] in
            let info = await client.fetchModelInfo(model: model)
            guard let self else { return }
            self.probeTasks[key] = nil
            self.contextProbing.remove(key)
            self.store(info, for: key)
        }
        probeTasks[key] = task
        await task.value
    }

    private func store(_ info: ModelContextInfo, for key: ContextKey) {
        var info = info
        // A refusal of images (replyFinished) is not something a probe of Strata's shared port can see.
        if info.acceptsImages == nil, contextInfo[key]?.acceptsImages == false { info.acceptsImages = false }
        if info == ModelContextInfo(model: info.model) {
            emptyProbeAt[key] = Date()
        } else {
            emptyProbeAt[key] = nil
            contextInfo[key] = info
        }
    }

    func reloadState(provider: Provider, model: String) -> ReloadState? {
        reloadStates[ContextKey(provider: provider, model: model)]
    }

    /// Forgets how the last reload ended (once the popover has shown it). A running one stays.
    func clearReloadState(provider: Provider, model: String) {
        let key = ContextKey(provider: provider, model: model)
        if reloadStates[key]?.isRunning == false { reloadStates[key] = nil }
    }

    /// Starts a reload that outlives the popover; its progress and outcome are in reloadStates.
    func startReload(provider: Provider, model: String, contextLength: Int, session: ConversationSession?) {
        Task {
            do {
                try await reloadModel(provider: provider, model: model, contextLength: contextLength, session: session)
            } catch {
                // Refused before it started (another reload running, no client): still say so.
                let key = ContextKey(provider: provider, model: model)
                if reloadStates[key]?.isRunning != true {
                    reloadStates[key] = .failed("Reload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// LM Studio: unloads the model and loads it again with `contextLength`. Only ever called
    /// after the user confirmed it in the context popover. Refuses while a reload of the same
    /// model on the same server is running. When the conversation used an instance id that the
    /// reload replaced, `session` switches to the id that exists now.
    @discardableResult
    func reloadModel(provider: Provider, model: String, contextLength: Int, session: ConversationSession? = nil) async throws -> ModelContextInfo {
        let key = ContextKey(provider: provider, model: model)
        let serverKey = Self.normalizedBaseURL(provider.baseURL) + "\n" + (contextInfo[key]?.modelKey ?? model)
        guard reloadStates[key]?.isRunning != true, !reloadsInFlight.contains(serverKey) else {
            throw ParleyError.api("\(model) is already being reloaded.")
        }
        let client = try ChatClient(baseURL: provider.baseURL, apiKey: try KeychainStore.apiKey(for: provider.id))
        // Claimed before the first await, so a second call is refused deterministically.
        reloadsInFlight.insert(serverKey)
        reloadStates[key] = .running(contextLength: contextLength)
        defer { reloadsInFlight.remove(serverKey) }
        // A probe that started earlier must not land after the reload and overwrite its result.
        if let probe = probeTasks[key] { await probe.value }
        contextProbing.insert(key)
        defer { contextProbing.remove(key) }
        do {
            let info = try await client.reloadModel(model, contextLength: contextLength)
            var notes: [String] = []
            if let applied = info.loadedContextLength, applied != contextLength {
                notes.append("The server loaded the model with \(applied.formatted()) tokens instead.")
            }
            let newKey = ContextKey(provider: provider, model: info.model)
            if info.model != model {
                // The old instance id no longer exists on the server.
                contextInfo[key] = nil
                if let session, ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider) == model {
                    session.conversation.settings.model = info.model
                    session.settingsChanged(debounced: false)
                    notes.append("This conversation now uses \(info.model).")
                }
            }
            store(info, for: newKey)
            let outcome = ReloadState.finished(note: notes.isEmpty ? nil : notes.joined(separator: " "))
            reloadStates[key] = outcome
            if newKey != key { reloadStates[newKey] = outcome }
            return info
        } catch {
            // The model may now be unloaded: show what the server says, then report the failure.
            store(await client.fetchModelInfo(model: model), for: key)
            reloadStates[key] = .failed("Reload failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func normalizedBaseURL(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// After a reply: a model that was not loaded has been loaded by the request (JIT), so its
    /// context length is known now; an overflow error may name the real limit. Also retries
    /// when no probe has learned anything yet (the server was not running when the chat opened,
    /// or the API key was fixed since).
    func replyFinished(in session: ConversationSession) {
        guard let provider = settings.resolvedProvider(for: session.conversation.settings) else { return }
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        guard !model.isEmpty, let last = session.conversation.messages.last, last.role == .assistant else { return }
        let key = ContextKey(provider: provider, model: model)
        if let error = last.error {
            if let n = ContextBudget.contextLength(fromError: error) {
                var info = contextInfo[key] ?? ModelContextInfo(model: model)
                if info.loadedContextLength == nil {
                    info.loadedContextLength = n
                    contextInfo[key] = info
                }
            }
            // Strata's shared port cannot say whether the model reads images; its refusal does.
            // Remembered (memory only), so the composer warns before the next image is sent.
            if ErrorPresentation.isStrataVisionRefusal(error) {
                let known = contextInfo[key]
                var info = known ?? ModelContextInfo(model: model, serverKind: .strata)
                if info.acceptsImages != false {
                    info.acceptsImages = false
                    contextInfo[key] = info
                }
                // Nothing was cached yet: still ask the server (store keeps the refusal).
                if known == nil {
                    Task { await refreshContextInfo(provider: provider, model: model, force: true) }
                }
            }
            return
        }
        // Images went through: an earlier refusal no longer holds (Pictures was turned on).
        if contextInfo[key]?.acceptsImages == false,
           session.conversation.messages.contains(where: { $0.attachments.contains { $0.kind == .image } }) {
            contextInfo[key]?.acceptsImages = nil
        }
        // A successful reply shows the server is reachable now: retry even within the
        // empty-probe interval.
        guard let info = contextInfo[key] else {
            Task { await refreshContextInfo(provider: provider, model: model, force: true) }
            return
        }
        if info.loadedContextLength == nil, info.serverKind == .lmStudio || info.serverKind == .ollama {
            Task { await refreshContextInfo(provider: provider, model: model, force: true) }
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
