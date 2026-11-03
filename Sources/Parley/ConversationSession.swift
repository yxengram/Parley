import Foundation
import Observation
import ParleyCore

/// One open (decrypted, in-memory) conversation plus its streaming and save state.
@MainActor
@Observable
final class ConversationSession: Identifiable {
    static let defaultTitle = "New Chat"

    nonisolated let id: UUID
    var conversation: Conversation
    var fileURL: URL
    /// Set for encrypted conversations. Kept only in memory; dropped on Lock.
    var encryption: EncryptionKey?

    // Streaming state
    private(set) var streamingMessageID: UUID?
    /// Mirrors `StreamAccumulator.isReasoning` for the in-flight message.
    private(set) var streamIsReasoning = false
    /// When the in-flight message started reasoning (for the live "Thinking… N s" label).
    private(set) var streamReasoningStartedAt: Date?
    /// Live speed of the in-flight reply, refreshed a few times per second (not per chunk), so
    /// only the views that show it re-render. Nil when nothing is streaming.
    private(set) var liveGeneration: LiveGeneration?
    var isStreaming: Bool { streamingMessageID != nil }

    struct LiveGeneration: Equatable {
        var tokensPerSecond: Double?
        /// Generated so far (reasoning + content).
        var tokens: Int
        /// True while counted from chunks rather than reported by the server.
        var isEstimated: Bool
        /// How far the server has read the prompt, until the first token (Strata, llama.cpp).
        var promptProgress: PromptProgress? = nil
    }

    // Composer state (memory only, never persisted).
    var draftText: String = ""
    var draftAttachments: [Attachment] = []
    var composerError: String?
    /// A user message being edited in the composer. History is truncated only when the
    /// edited message is sent; cancelling leaves the conversation untouched.
    var pendingEditMessageID: UUID?
    /// The draft that was in the composer when an edit started; restored on cancel.
    @ObservationIgnored private var draftBeforeEdit: (text: String, attachments: [Attachment])?

    /// Last save failure, shown as a banner.
    var saveError: String?

    var isEncrypted: Bool { encryption != nil }

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var debouncedSave: DispatchWorkItem?
    @ObservationIgnored private var lastSaveDate = Date.distantPast
    /// Once closed (locked, deleted), the session never writes again.
    @ObservationIgnored private(set) var isClosed = false
    /// Called on the main actor after each save is enqueued (library bookkeeping).
    @ObservationIgnored var didEnqueueSave: ((ConversationSession) -> Void)?
    /// What AppState knows about a provider's model (server kind, context length, limits); set
    /// when the session is registered. Nil (or a nil answer) sends a plain OpenAI-style request.
    @ObservationIgnored var serverInfo: ((Provider, String) -> ModelContextInfo?)?
    /// What is known to be on disk: set only after a write succeeded (or on load). Lets
    /// Lock/quit skip rewriting an unchanged file, and never skip after a failed save.
    /// Copy-on-write keeps this cheap.
    @ObservationIgnored private var lastWritten: Conversation?
    /// Monotonic save counter. A save result is applied only if it is newer than the last
    /// applied one, so a late completion cannot overwrite a newer outcome.
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var lastAppliedGeneration = 0

    init(conversation: Conversation, fileURL: URL, encryption: EncryptionKey?) {
        self.id = conversation.id
        self.conversation = conversation
        self.fileURL = fileURL
        self.encryption = encryption
        self.lastWritten = conversation
    }

    /// Call after creating a conversation that does not exist on disk yet.
    func markUnsaved() {
        lastWritten = nil
    }

    // MARK: - Saving

    /// Snapshot and enqueue a write now.
    func saveNow() {
        guard !isClosed else { return }
        debouncedSave?.cancel()
        debouncedSave = nil
        lastSaveDate = Date()
        let snapshot = conversation
        let key = encryption
        let url = fileURL
        saveGeneration += 1
        let generation = saveGeneration
        ConversationWriter.save(snapshot, encryption: key, to: url) { [weak self] error in
            Task { @MainActor in
                self?.applySaveResult(error, snapshot: snapshot, generation: generation)
            }
        }
        didEnqueueSave?(self)
    }

    private func applySaveResult(_ error: String?, snapshot: Conversation, generation: Int) {
        guard generation > lastAppliedGeneration else { return }
        lastAppliedGeneration = generation
        if let error {
            saveError = error
            lastWritten = nil   // unknown what is on disk now: never skip the next flush
        } else {
            saveError = nil
            lastWritten = snapshot
        }
    }

    /// Save after `delay` seconds unless another save happens first.
    func scheduleSave(after delay: TimeInterval = 0.6) {
        guard !isClosed else { return }
        debouncedSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
        debouncedSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Synchronous write (used on quit, Lock and encryption changes). Waits for queued writes first.
    /// With `onlyIfChanged`, a conversation known to be on disk unchanged is not rewritten.
    /// Returns nil on success, or the error message (also shown as `saveError`).
    @discardableResult
    func flushSync(onlyIfChanged: Bool = false) -> String? {
        guard !isClosed else { return nil }
        debouncedSave?.cancel()
        debouncedSave = nil
        if onlyIfChanged && lastWritten == conversation { return nil }
        lastSaveDate = Date()
        let snapshot = conversation
        saveGeneration += 1
        let generation = saveGeneration
        let error = ConversationWriter.saveSync(snapshot, encryption: encryption, to: fileURL)
        applySaveResult(error, snapshot: snapshot, generation: generation)
        if error == nil { didEnqueueSave?(self) }
        return error
    }

    /// Stops streaming and prevents any further writes. Optionally writes a final copy first.
    /// When saving fails, the session stays open (nothing in memory is dropped) and the error
    /// message is returned; nil means the session is closed.
    @discardableResult
    func close(saving: Bool) -> String? {
        if let task = streamTask {
            task.cancel()
            finalizeStreamingMessage(stoppedEarly: true)
        }
        if saving, let error = flushSync(onlyIfChanged: true) {
            return error
        }
        debouncedSave?.cancel()
        debouncedSave = nil
        isClosed = true
        streamTask = nil
        streamingMessageID = nil
        return nil
    }

    // MARK: - Settings

    func settingsChanged(debounced: Bool) {
        conversation.updatedAt = Date()
        if debounced { scheduleSave() } else { saveNow() }
    }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        conversation.updatedAt = Date()
        saveNow()
    }

    // MARK: - Sending

    /// Appends a user message and requests a reply.
    func send(text: String, attachments: [Attachment], settings: AppSettings) {
        guard !isStreaming, !isClosed else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if let editID = pendingEditMessageID {
            pendingEditMessageID = nil
            draftBeforeEdit = nil
            if let index = conversation.messages.firstIndex(where: { $0.id == editID }) {
                conversation.truncate(keepingThrough: index - 1)
            }
        }
        let isFirstUserMessage = !conversation.messages.contains { $0.role == .user }
        let message = Message(role: .user, content: text, attachments: attachments)
        conversation.messages.append(message)
        if isFirstUserMessage && conversation.title == Self.defaultTitle {
            conversation.title = Self.autoTitle(text: trimmed, attachments: attachments)
        }
        conversation.updatedAt = Date()
        startReply(settings: settings)
    }

    static func autoTitle(text: String, attachments: [Attachment]) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let source = collapsed.isEmpty ? (attachments.first?.filename ?? defaultTitle) : collapsed
        if source.count <= 40 { return source }
        return String(source.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Streams an assistant reply to the current history.
    func startReply(settings: AppSettings) {
        guard !isStreaming, !isClosed else { return }

        // History excludes the placeholder we are about to append.
        let history = conversation.messages
        let provider = settings.resolvedProvider(for: conversation.settings)
        let model = Self.effectiveModel(settings: conversation.settings, provider: provider)

        var placeholder = Message(role: .assistant, content: "", model: model.isEmpty ? nil : model, isComplete: false)

        guard let provider else {
            placeholder.error = "No API provider is configured. Add one in Settings."
            conversation.messages.append(placeholder)
            conversation.updatedAt = Date()
            saveNow()
            return
        }
        guard !model.isEmpty else {
            placeholder.error = "No model selected. Pick a model in the toolbar or set a default model for \(provider.name) in Settings."
            conversation.messages.append(placeholder)
            conversation.updatedAt = Date()
            saveNow()
            return
        }

        let client: ChatClient
        do {
            let apiKey = try KeychainStore.apiKey(for: provider.id)
            client = try ChatClient(baseURL: provider.baseURL, apiKey: apiKey)
        } catch {
            placeholder.error = error.localizedDescription
            conversation.messages.append(placeholder)
            conversation.updatedAt = Date()
            saveNow()
            return
        }

        var options = ChatRequestOptions(settings: conversation.settings)
        options.model = model
        let info = serverInfo?(provider, model)
        options.serverKind = info?.serverKind
        options.maxRequestBytes = info?.maxRequestBytes

        conversation.messages.append(placeholder)
        conversation.updatedAt = Date()
        // Reset before the stream task can run: a Stop/Lock/quit in between must not apply
        // the previous reply's accumulator to this new message.
        liveAccumulator = StreamAccumulator()
        liveMeter = GenerationMeter(requestStartedAt: Date())
        liveGeneration = LiveGeneration(tokensPerSecond: nil, tokens: 0, isEstimated: true)
        streamingMessageID = placeholder.id
        streamIsReasoning = false
        streamReasoningStartedAt = nil
        saveNow()

        let messageID = placeholder.id
        streamTask = Task { [weak self] in
            await self?.runStream(client: client, history: history, options: options, messageID: messageID)
        }
    }

    static func effectiveModel(settings: ConversationSettings, provider: Provider?) -> String {
        let m = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        return provider?.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @ObservationIgnored private var liveAccumulator = StreamAccumulator()
    @ObservationIgnored private var liveMeter = GenerationMeter()
    /// How often the live speed is published.
    static let liveStatsInterval: TimeInterval = 0.25

    private func runStream(client: ChatClient, history: [Message], options: ChatRequestOptions, messageID: UUID) async {
        // Stopped (or closed) before the task first ran: never open the request.
        guard streamingMessageID == messageID, !isClosed else { return }
        if Task.isCancelled {
            finalizeStreamingMessage(stoppedEarly: true)
            return
        }
        var lastFlush = Date.distantPast
        var lastStats = Date.distantPast
        var failure: Error?
        do {
            for try await delta in client.streamChat(messages: history, options: options) {
                if Task.isCancelled { break }
                let now = Date()
                liveAccumulator.apply(delta, now: now)
                liveMeter.record(delta, now: now)
                if now.timeIntervalSince(lastStats) >= Self.liveStatsInterval {
                    lastStats = now
                    publishLiveGeneration()
                }
                if now.timeIntervalSince(lastFlush) >= 0.05 {
                    lastFlush = now
                    applyAccumulator(to: messageID)
                    if now.timeIntervalSince(lastSaveDate) >= 2 {
                        saveNow()
                    }
                }
            }
        } catch {
            failure = error
        }

        // Stop/lock may already have finalized the message.
        guard streamingMessageID == messageID, !isClosed else { return }
        liveAccumulator.finish()
        applyAccumulator(to: messageID)

        if Task.isCancelled || Self.isCancellation(failure) {
            finalizeStreamingMessage(stoppedEarly: true)
        } else if let failure {
            if let idx = index(of: messageID) {
                conversation.messages[idx].error = failure.localizedDescription
                conversation.messages[idx].isComplete = false
            }
            endStreaming()
        } else {
            if let idx = index(of: messageID) {
                let msg = conversation.messages[idx]
                let isEmpty = msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (msg.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isEmpty {
                    // A 200 stream that ended with nothing: show it as a failure with Retry.
                    conversation.messages[idx].error = "The server ended the reply without sending any content."
                    conversation.messages[idx].isComplete = false
                } else {
                    conversation.messages[idx].isComplete = true
                }
            }
            endStreaming()
        }
    }

    /// Context tokens in use (ContextBudget.usage), the in-flight reply's live count included.
    /// While streaming, the history part is computed once per reply: the status strip
    /// re-renders on every message flush (20 Hz), and a long conversation or a large text
    /// attachment would otherwise be re-estimated each time.
    func contextUsage() -> ContextUsage {
        let history: ContextUsage
        if let id = streamingMessageID {
            let key = HistoryUsageKey(inFlightID: id, messageCount: conversation.messages.count,
                                      systemPrompt: conversation.settings.systemPrompt)
            if let cached = historyUsageCache, cached.key == key {
                history = cached.usage
            } else {
                history = ContextBudget.usage(messages: conversation.messages, systemPrompt: key.systemPrompt, inFlightID: id)
                historyUsageCache = (key, history)
            }
        } else {
            historyUsageCache = nil
            history = ContextBudget.usage(messages: conversation.messages, systemPrompt: conversation.settings.systemPrompt)
        }
        guard let live = liveGeneration, live.tokens > 0 else { return history }
        return ContextUsage(tokens: history.tokens + live.tokens, isEstimated: history.isEstimated || live.isEstimated)
    }

    private struct HistoryUsageKey: Equatable {
        let inFlightID: UUID
        let messageCount: Int
        let systemPrompt: String
    }

    @ObservationIgnored private var historyUsageCache: (key: HistoryUsageKey, usage: ContextUsage)?

    private func publishLiveGeneration() {
        let live = LiveGeneration(
            tokensPerSecond: liveMeter.tokensPerSecond,
            tokens: liveMeter.generatedTokens,
            isEstimated: liveMeter.isEstimated,
            promptProgress: liveMeter.promptProgress
        )
        if live != liveGeneration { liveGeneration = live }
    }

    private static func isCancellation(_ error: Error?) -> Bool {
        guard let error else { return false }
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private func index(of messageID: UUID) -> Int? {
        conversation.messages.lastIndex { $0.id == messageID }
    }

    private func applyAccumulator(to messageID: UUID) {
        guard let idx = index(of: messageID) else { return }
        let acc = liveAccumulator
        var msg = conversation.messages[idx]
        msg.content = acc.content
        msg.reasoning = acc.reasoning.isEmpty ? nil : acc.reasoning
        msg.reasoningDuration = acc.reasoningDuration
        msg.usage = acc.usage
        if msg != conversation.messages[idx] {
            conversation.messages[idx] = msg
        }
        if streamIsReasoning != acc.isReasoning {
            streamIsReasoning = acc.isReasoning
        }
        if streamReasoningStartedAt != acc.reasoningStartedAt {
            streamReasoningStartedAt = acc.reasoningStartedAt
        }
    }

    /// Keeps the partial reply with isComplete=false.
    private func finalizeStreamingMessage(stoppedEarly: Bool) {
        guard let messageID = streamingMessageID else { return }
        liveAccumulator.finish()
        applyAccumulator(to: messageID)
        if let idx = index(of: messageID) {
            conversation.messages[idx].isComplete = false
        }
        endStreaming()
    }

    private func endStreaming() {
        if let id = streamingMessageID, let idx = index(of: id) {
            conversation.messages[idx].stats = liveMeter.finalStats()
        }
        liveGeneration = nil
        streamTask = nil
        streamingMessageID = nil
        streamIsReasoning = false
        streamReasoningStartedAt = nil
        conversation.updatedAt = Date()
        saveNow()
    }

    /// Stop button: cancel the request and keep the partial message.
    func stop() {
        guard let task = streamTask else { return }
        task.cancel()
        finalizeStreamingMessage(stoppedEarly: true)
    }

    // MARK: - History editing (disabled while streaming)

    func rollback(toMessageAt index: Int) {
        guard !isStreaming, index >= 0, index < conversation.messages.count else { return }
        pendingEditMessageID = nil
        conversation.truncate(keepingThrough: index)
        saveNow()
    }

    /// Puts a user message back in the composer and drops it and everything after it.
    func editAndResend(messageAt index: Int) {
        guard !isStreaming, conversation.messages.indices.contains(index) else { return }
        let message = conversation.messages[index]
        guard message.role == .user else { return }
        draftText = message.content
        draftAttachments = message.attachments
        conversation.truncate(keepingThrough: index - 1)
        saveNow()
    }

    /// Staged edit (what the UI uses): puts a user message in the composer without changing
    /// the history. Sending replaces that message and everything after it; `cancelEdit` keeps all.
    func beginEdit(messageAt index: Int) {
        guard !isStreaming, conversation.messages.indices.contains(index) else { return }
        let message = conversation.messages[index]
        guard message.role == .user else { return }
        if pendingEditMessageID == nil {
            draftBeforeEdit = (draftText, draftAttachments)
        }
        pendingEditMessageID = message.id
        draftText = message.content
        draftAttachments = message.attachments
        composerError = nil
    }

    func cancelEdit() {
        guard pendingEditMessageID != nil else { return }
        pendingEditMessageID = nil
        draftText = draftBeforeEdit?.text ?? ""
        draftAttachments = draftBeforeEdit?.attachments ?? []
        draftBeforeEdit = nil
    }

    /// Index of the message being edited, if any.
    var pendingEditIndex: Int? {
        guard let id = pendingEditMessageID else { return nil }
        return conversation.messages.firstIndex { $0.id == id }
    }

    /// Index of the last user message (for "Edit Last Message" and ↑ in the composer).
    var lastUserMessageIndex: Int? {
        conversation.messages.lastIndex { $0.role == .user }
    }

    /// True when the conversation ends with a user message that has no reply yet.
    var awaitsReply: Bool {
        !isStreaming && conversation.messages.last?.role == .user
    }

    /// Drops an assistant message (and later ones) and asks again.
    func regenerate(messageAt index: Int, settings: AppSettings) {
        guard !isStreaming, conversation.messages.indices.contains(index) else { return }
        guard conversation.messages[index].role == .assistant else { return }
        pendingEditMessageID = nil
        conversation.truncate(keepingThrough: index - 1)
        startReply(settings: settings)
    }
}
