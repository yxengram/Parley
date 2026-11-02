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
    var isStreaming: Bool { streamingMessageID != nil }

    // Composer state (memory only, never persisted).
    var draftText: String = ""
    var draftAttachments: [Attachment] = []
    var composerError: String?

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

        conversation.messages.append(placeholder)
        conversation.updatedAt = Date()
        // Reset before the stream task can run: a Stop/Lock/quit in between must not apply
        // the previous reply's accumulator to this new message.
        liveAccumulator = StreamAccumulator()
        streamingMessageID = placeholder.id
        streamIsReasoning = false
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

    private func runStream(client: ChatClient, history: [Message], options: ChatRequestOptions, messageID: UUID) async {
        // Stopped (or closed) before the task first ran: never open the request.
        guard streamingMessageID == messageID, !isClosed else { return }
        if Task.isCancelled {
            finalizeStreamingMessage(stoppedEarly: true)
            return
        }
        var lastFlush = Date.distantPast
        var failure: Error?
        do {
            for try await delta in client.streamChat(messages: history, options: options) {
                if Task.isCancelled { break }
                liveAccumulator.apply(delta)
                let now = Date()
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
        streamTask = nil
        streamingMessageID = nil
        streamIsReasoning = false
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

    /// Drops an assistant message (and later ones) and asks again.
    func regenerate(messageAt index: Int, settings: AppSettings) {
        guard !isStreaming, conversation.messages.indices.contains(index) else { return }
        guard conversation.messages[index].role == .assistant else { return }
        conversation.truncate(keepingThrough: index - 1)
        startReply(settings: settings)
    }
}
