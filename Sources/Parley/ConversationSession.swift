import Foundation
import Observation
import ParleyCore

/// What a session needs from the app to run tools. Set when the session is registered; nil never
/// offers any.
@MainActor
struct ConversationToolServices {
    var host: MCPToolHost
    /// The servers this conversation lists that are switched on.
    var enabledServers: (ConversationSettings) -> [MCPServerConfig]
    /// What this provider's model refused of `tools` this launch.
    var refusal: (Provider, String) -> ToolsRefusal?
    var markRefused: (Provider, String, ToolsRefusal) -> Void
    var allowance: (MCPToolBinding) -> ToolAllowance
    var setAlwaysAllowed: (MCPToolBinding) -> Void
    /// A call waits for the user, who may be in another app.
    var approvalNeeded: () -> Void = {}
    var maxRounds: () -> Int
    /// For ContextBudget.toolResultBudget.
    var contextLimit: (Provider, String) -> ContextLimit?
    /// For the card of a built-in file tool, which names the folder.
    var builtInFolderPath: () -> String? = { nil }
}

enum ToolAllowance {
    case ask, always
    /// "Always Allow" was chosen for a definition that has changed since.
    case changed
}

/// The call waiting for the user. Everything on the approval card comes from here.
struct PendingToolApproval: Equatable, Identifiable {
    /// The call id.
    let id: String
    let serverName: String
    /// "Local command: npx", the URL's host, or for a built-in tool what it reaches.
    let serverDetail: String
    let toolName: String
    /// Shown in a disclosure, labelled with who wrote it (`definitionLabel`).
    let description: String?
    /// The parameters as the model was told about them, in the same disclosure.
    let parameters: String
    /// Pretty JSON of what will be sent.
    let arguments: String
    let definitionChanged: Bool
    /// ReAct: the call was read from the model's text, which can repeat tool output. Weaker evidence
    /// than a structured call, so this card never offers Always Allow.
    var readFromText = false
    /// A built-in tool that reads files or a website: what it reads can steer the model, so every
    /// call stops at this card.
    var asksEveryTime = false
    var isBuiltIn = false

    var offersAlwaysAllow: Bool { !readFromText && !asksEveryTime }
    var definitionLabel: String { isBuiltIn ? "Definition from Parley" : "Definition from the server" }
}

enum ToolApprovalDecision {
    case allowOnce, alwaysAllow, deny
    /// Stop, Lock, close or quit.
    case cancelled
}

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
    /// What the in-flight reply is doing. Nil when nothing is streaming.
    private(set) var replyPhase: ReplyPhase?
    /// The tool call waiting for the user, shown as a card in the reply.
    private(set) var pendingApproval: PendingToolApproval?
    /// The call running now.
    private(set) var activeCallID: String?
    /// When the current round's request went out (message.createdAt is wrong after round 1).
    private(set) var roundStartedAt: Date?

    enum ReplyPhase: Equatable {
        case generating
        /// Server names.
        case connecting([String])
        case awaitingApproval
        /// Tool name.
        case runningTool(String)
    }

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
    /// Waits (briefly, cancellable) for AppState's probe of the server. Used before a request whose
    /// fields depend on the server kind when nothing is known yet; nil sends at once. The Bool asks
    /// for the longer wait a thinking budget needs.
    @ObservationIgnored var awaitServerInfo: ((Provider, String, Bool) async -> ModelContextInfo?)?
    /// Whether this provider's model refused one of these "no thinking" fields earlier this launch,
    /// and how a refusal is recorded (AppState.thinkingOffRejections).
    @ObservationIgnored var thinkingOffRejected: ((Provider, String, [String]) -> Bool)?
    @ObservationIgnored var markThinkingOffRejected: ((Provider, String, [String]) -> Void)?
    /// Tool calling (AppState.toolServices).
    @ObservationIgnored var tools: ConversationToolServices?
    /// Resumed exactly once: by the card's buttons, or by `finalizeStreamingMessage`.
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ToolApprovalDecision, Never>?
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
            placeholder.error = "No model selected. Pick a model at the top of the window or set a default model for \(provider.name) in Settings."
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
        // "None (no thinking)" and the thinking budget are shaped per server kind: right after
        // launch the probe may still be running, and sending without its answer would drop them.
        // What was refused earlier is checked once the kind is known (streamRound). Tools wait too:
        // without the kind, a Strata runtime model would silently lose them.
        let servers = tools?.enabledServers(conversation.settings) ?? []
        // Built-in tools do not wait: a conversation with only those is a plain chat until a model
        // uses one, and it asks the server nothing a plain chat would not.
        let waitsForServer = info == nil
            && (conversation.settings.disablesThinking == true || conversation.settings.reasoningBudgetTokens != nil
                || !ReplyTarget.realServers(in: servers).isEmpty)

        conversation.messages.append(placeholder)
        conversation.updatedAt = Date()
        // Reset before the stream task can run: a Stop/Lock/quit in between must not apply
        // the previous reply's accumulator to this new message.
        beginRound()
        streamingMessageID = placeholder.id
        liveSendsThinkingOff = false
        saveNow()

        let messageID = placeholder.id
        let target = ReplyTarget(provider: provider, model: model, waitsForServer: waitsForServer, servers: servers,
                                 usesReAct: conversation.settings.usesReAct)
        streamTask = Task { [weak self] in
            await self?.runReply(client: client, history: history, options: options, messageID: messageID, target: target)
        }
    }

    private struct ReplyTarget {
        let provider: Provider
        let model: String
        let waitsForServer: Bool
        /// Empty: no tools are offered and the request is today's.
        var servers: [MCPServerConfig]
        /// `toolMode`, read once at the start of the reply.
        let usesReAct: Bool

        static func realServers(in servers: [MCPServerConfig]) -> [MCPServerConfig] {
            servers.filter { $0.kind != MCPServerConfig.kindBuiltIn }
        }

        /// The servers the user added: the ones that take time to start and can fail.
        var realServers: [MCPServerConfig] { Self.realServers(in: servers) }

        /// Parley's own tools and nothing the user added. The user never asked for a tool in this
        /// conversation in particular, so a model without tools must leave it a plain chat: tools
        /// are left out, and no note says so.
        var offersOnlyBuiltIns: Bool { !servers.isEmpty && realServers.isEmpty }
    }

    static func effectiveModel(settings: ConversationSettings, provider: Provider?) -> String {
        let m = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        return provider?.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @ObservationIgnored private var liveAccumulator = StreamAccumulator()
    @ObservationIgnored private var liveMeter = GenerationMeter()
    /// Set while the request in flight offers tools as ReAct text: the accumulator keeps the raw text
    /// for the parser, and the message shows what this says. Nil for every other request, so a
    /// request at the round cap, whose text is not parsed, shows as it came.
    @ObservationIgnored private var liveReAct: ReActScanner?
    /// The in-flight request carries the "no thinking" fields (cleared when the server refused them).
    @ObservationIgnored private var liveSendsThinkingOff = false
    /// The server kind that request was shaped for (stored with an "ignored" note).
    @ObservationIgnored private var liveThinkingOffServerKind: InferenceServerKind?
    /// How often the live speed is published.
    static let liveStatsInterval: TimeInterval = 0.25

    private enum RoundOutcome {
        /// The request finished.
        case ended
        case stopped
        case failed(Error)
    }

    private func isCurrent(_ messageID: UUID) -> Bool {
        streamingMessageID == messageID && !isClosed
    }

    /// The whole reply: requests, and the tool calls between them, until the model answers.
    /// One Task from send to end, so Stop and Lock cancel it wherever it is. Every await is followed
    /// by `isCurrent`: Stop has already finalized the message by then.
    private func runReply(
        client: ChatClient, history: [Message], options: ChatRequestOptions, messageID: UUID, target: ReplyTarget
    ) async {
        // Stopped (or closed) before the task first ran: never open the request.
        guard isCurrent(messageID) else { return }
        if Task.isCancelled {
            finalizeStreamingMessage(stoppedEarly: true)
            return
        }
        var options = options
        var info = serverInfo?(target.provider, target.model)
        if target.waitsForServer, let awaitServerInfo {
            let forBudget = (options.reasoningBudgetTokens != nil && !options.disablesThinking) || !target.realServers.isEmpty
            info = await awaitServerInfo(target.provider, target.model, forBudget)
            // Stop (or Lock) during the wait has already finalized the message.
            guard isCurrent(messageID) else { return }
            if Task.isCancelled {
                finalizeStreamingMessage(stoppedEarly: true)
                return
            }
            options.serverKind = info?.serverKind
            options.maxRequestBytes = info?.maxRequestBytes
        }

        // The wait above can be long, and the user may have switched a server off in it.
        var target = target
        if !target.servers.isEmpty, let tools { target.servers = tools.enabledServers(conversation.settings) }

        var catalog: MCPToolCatalog?
        if !target.servers.isEmpty, let tools {
            // ReAct sends no `tools`, so neither gate applies: those servers are what it is for.
            if !target.usesReAct, info?.ignoresTools == true {
                if !target.offersOnlyBuiltIns { addNote(ToolNote.toolsNotOffered, to: messageID) }
            } else if !target.usesReAct, let refusal = tools.refusal(target.provider, target.model),
                      refusal.kind == .unsupported || target.offersOnlyBuiltIns {
                if !target.offersOnlyBuiltIns { addNote(ToolNote.toolsNotAccepted, refusal.message, to: messageID) }
            } else {
                let starting = target.realServers.map(\.name)
                if !starting.isEmpty { replyPhase = .connecting(starting) }
                let listed = await tools.host.catalog(for: target.servers)
                guard isCurrent(messageID) else { return }
                if Task.isCancelled {
                    finalizeStreamingMessage(stoppedEarly: true)
                    return
                }
                for failure in listed.unavailable {
                    addNote(ToolNote.serverUnavailable, "\(failure.name): \(failure.reason)", to: messageID)
                }
                catalog = listed
                if !listed.chatTools.isEmpty {
                    var definitionTokens = listed.definitionTokens
                    if target.usesReAct {
                        let react = ReActRequest(tools: listed.chatTools, nonce: ReActPrompt.nonce(conversationID: conversation.id))
                        options.react = react
                        definitionTokens = ContextBudget.estimateTokens(ReActPrompt.block(tools: react.tools, nonce: react.nonce))
                    } else {
                        options.tools = listed.chatTools
                        options.toolsAreOptional = target.offersOnlyBuiltIns
                    }
                    if let idx = index(of: messageID) {
                        conversation.messages[idx].toolDefinitionTokens = definitionTokens
                    }
                }
            }
        }

        var roundsRun = 0
        while true {
            beginRound()
            let outcome = await streamRound(client: client, messages: history + inFlightCopy(messageID), options: &options,
                                            messageID: messageID, target: target)
            // Stop/lock may already have finalized the message.
            guard isCurrent(messageID) else { return }
            liveAccumulator.finish()
            applyAccumulator(to: messageID)
            switch outcome {
            case .stopped:
                finalizeStreamingMessage(stoppedEarly: true)
                return
            case .failed(let failure):
                if let idx = index(of: messageID) {
                    conversation.messages[idx].error = failure.localizedDescription
                    conversation.messages[idx].isComplete = false
                }
                endStreaming()
                return
            case .ended:
                break
            }

            // The accumulated calls drive the loop, not finish_reason, except that a reply cut off
            // by "length" never runs them: its last call may be incomplete.
            var calls = liveAccumulator.toolCalls.finalCalls(existingIDs: callIDs(in: messageID))
            // In ReAct the call comes from the text. Native calls this request did not ask for never run.
            let readsText = ChatClient.sendsReact(options)
            if readsText {
                if !calls.isEmpty { addNote(ToolNote.nativeCallsIgnored, ToolNote.nativeCallsIgnoredText, to: messageID) }
                calls = splitReActRound(messageID)
            }
            guard !calls.isEmpty else {
                finishReply(messageID)
                return
            }
            guard ChatClient.sendsTools(options) || readsText, liveAccumulator.finishReason != "length", let catalog, let tools else {
                addNote(ToolNote.callsNotRun, to: messageID)
                finishReply(messageID)
                return
            }
            commitRound(messageID, calls: calls, catalog: catalog, fromText: readsText)
            await runCalls(calls.map(\.id), messageID: messageID, catalog: catalog, tools: tools, target: target, fromText: readsText)
            guard isCurrent(messageID) else { return }
            if Task.isCancelled {
                finalizeStreamingMessage(stoppedEarly: true)
                return
            }
            roundsRun += 1
            if roundsRun >= tools.maxRounds() {
                options.omitsTools = true
                addNote(ToolNote.roundLimit, "\(roundsRun)", to: messageID)
            }
        }
    }

    /// A fresh accumulator and meter for one request: tool time never lowers tok/s, and time to
    /// first token measures the server.
    private func beginRound() {
        liveAccumulator = StreamAccumulator()
        liveMeter = GenerationMeter(requestStartedAt: Date())
        liveGeneration = LiveGeneration(tokensPerSecond: nil, tokens: 0, isEstimated: true)
        streamIsReasoning = false
        streamReasoningStartedAt = nil
        roundStartedAt = Date()
        replyPhase = .generating
        activeCallID = nil
        liveReAct = nil
    }

    /// One request and its stream. `options` keeps what the server refused, for the later rounds.
    private func streamRound(
        client: ChatClient, messages: [Message], options: inout ChatRequestOptions, messageID: UUID, target: ReplyTarget
    ) async -> RoundOutcome {
        // The fields "None" takes on this server kind; left out when this provider's model refused
        // one of them earlier this launch. That reply says so once the server has answered it.
        var notedNotAccepted = false
        var pendingNotAccepted = false
        let thinkingOffFields = ChatClient.sentThinkingOffFields(options)
        if !thinkingOffFields.isEmpty, thinkingOffRejected?(target.provider, target.model, thinkingOffFields) == true {
            options.omitsThinkingOff = true
            pendingNotAccepted = true
        }
        liveSendsThinkingOff = !ChatClient.sentThinkingOffFields(options).isEmpty
        liveThinkingOffServerKind = options.serverKind
        liveReAct = ChatClient.sendsReact(options) ? ReActScanner() : nil
        var lastFlush = Date.distantPast
        var lastStats = Date.distantPast
        var failure: Error?
        do {
            for try await delta in client.streamChat(messages: messages, options: options) {
                if Task.isCancelled { break }
                if let refusal = delta.toolsRejected {
                    // The server refused `tools` and accepted the request without them. One bad
                    // schema from one server must not turn tools off for the model: only a plain
                    // lack of support is remembered, unless Parley's own definitions were the only
                    // ones sent. The gate above spares a real server's chat from that memory, and
                    // `.unconfirmed` may have been a passing fault, so it is never kept.
                    options.omitsTools = true
                    if refusal.kind == .unsupported || (target.offersOnlyBuiltIns && refusal.kind == .definitions) {
                        tools?.markRefused(target.provider, target.model, refusal)
                    }
                    if target.offersOnlyBuiltIns {
                        // As if they had never been offered: the definitions are not in this request.
                        if let idx = index(of: messageID) { conversation.messages[idx].toolDefinitionTokens = nil }
                    } else {
                        addNote(ToolNote.toolsNotAccepted, refusal.message, to: messageID)
                    }
                    continue
                }
                if delta.thinkingOffRejected {
                    // The server refused "no thinking" and accepted the request without it.
                    markThinkingOffRejected?(target.provider, target.model, thinkingOffFields)
                    liveSendsThinkingOff = false
                    pendingNotAccepted = true
                }
                if pendingNotAccepted, !notedNotAccepted {
                    // The server has answered (a delta only comes from a 2xx).
                    notedNotAccepted = true
                    if let idx = index(of: messageID) { conversation.messages[idx].thinkingOffNotAccepted = true }
                }
                if delta.thinkingOffRejected { continue }
                let now = Date()
                liveAccumulator.apply(delta, now: now)
                liveMeter.record(delta, now: now)
                if liveReAct != nil {
                    liveReAct?.feed(liveAccumulator.content, generation: liveAccumulator.contentGeneration)
                    // No `stop` is sent: a thinking model can write "Observation:" in its reasoning,
                    // which a server stop string would cut. Leaving ends the stream instead (its
                    // onTermination cancels the request), so the rest never arrives, and neither do
                    // usage and finish_reason. It leaves at the first text after the input, not at
                    // the input's end, so that a `</think>` right after the input can still turn
                    // it into reasoning. A model that stops by itself ends the stream anyway.
                    if liveReAct?.actionIsFollowed == true { break }
                }
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
        if Task.isCancelled || Self.isCancellation(failure) { return .stopped }
        if let failure { return .failed(failure) }
        return .ended
    }

    /// A request needs the reply's finished rounds, as a message after the history. Empty until
    /// there is one, so the first request carries today's history.
    private func inFlightCopy(_ messageID: UUID) -> [Message] {
        guard let idx = index(of: messageID), !(conversation.messages[idx].toolRounds ?? []).isEmpty else { return [] }
        return [conversation.messages[idx]]
    }

    private func callIDs(in messageID: UUID) -> Set<String> {
        guard let idx = index(of: messageID) else { return [] }
        return Set((conversation.messages[idx].toolRounds ?? []).flatMap { $0.calls.map(\.id) })
    }

    private func addNote(_ kind: String, _ detail: String? = nil, to messageID: UUID) {
        guard let idx = index(of: messageID) else { return }
        let note = ToolNote(kind: kind, detail: detail)
        if conversation.messages[idx].toolNotes?.contains(note) == true { return }
        conversation.messages[idx].toolNotes = (conversation.messages[idx].toolNotes ?? []) + [note]
    }

    /// ReAct shows less than came: labels and an Action that did not run are not an answer.
    static let nothingToShow = "The reply has nothing to show: the model wrote only format labels or a tool call that did not run."

    /// Ends a reply whose last request finished. Empty text is a failure only with no tool rounds:
    /// after them the model may simply have nothing to add.
    private func finishReply(_ messageID: UUID) {
        if let idx = index(of: messageID) {
            let msg = conversation.messages[idx]
            let isEmpty = msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (msg.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let textCame = liveReAct != nil && !liveAccumulator.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty, (msg.toolRounds ?? []).isEmpty {
                // A 200 stream that ended with nothing: show it as a failure with Retry.
                conversation.messages[idx].error = textCame ? Self.nothingToShow : "The server ended the reply without sending any content."
                conversation.messages[idx].isComplete = false
            } else {
                // An Action cut off after a tool result is not "wrote nothing"; its own note says so.
                let saidSo = textCame && msg.toolNotes?.contains(ToolNote(kind: ToolNote.callsNotRun)) == true
                if isEmpty, !saidSo { addNote(ToolNote.emptyAfterTools, to: messageID) }
                conversation.messages[idx].isComplete = true
            }
        }
        endStreaming()
    }

    // MARK: - Tool rounds

    /// Reads the round's raw text: an Action leaves its Thought as the content, and an answer leaves
    /// the answer, with its Thought beside it. Returns the call, if there is one.
    private func splitReActRound(_ messageID: UUID) -> [ToolCallRecord] {
        guard let idx = index(of: messageID) else { return [] }
        switch ReActParser.parse(liveAccumulator.content) {
        case .answer(let thought, let text):
            conversation.messages[idx].content = text
            conversation.messages[idx].reactThought = thought
            return []
        case .action(let thought, let name, let arguments):
            conversation.messages[idx].content = thought
            conversation.messages[idx].reactThought = nil
            // As in native mode, where `finalCalls` drops it. A round holding it would be an invalid
            // `tool_calls` entry in every later native request, and no model can be told about it.
            guard !name.isEmpty else { return [] }
            let id = ReActParser.newCallID(existingIDs: callIDs(in: messageID))
            return [ToolCallRecord(id: id, name: name, arguments: arguments)]
        }
    }

    /// A name read from text must match exactly: `binding(forFunctionName:)` also takes a near match,
    /// which is for servers that normalize structured names.
    private func binding(for name: String, in catalog: MCPToolCatalog, fromText: Bool) -> MCPToolBinding? {
        fromText ? catalog.exactBinding(forFunctionName: name) : catalog.binding(forFunctionName: name)
    }

    /// Moves the current round from the top-level fields into `toolRounds` and resets everything
    /// live in the same step: otherwise a Stop during approval would write this round's text back as
    /// the final round's, and the strip would count it twice while a tool runs.
    private func commitRound(_ messageID: UUID, calls: [ToolCallRecord], catalog: MCPToolCatalog, fromText: Bool) {
        guard let idx = index(of: messageID) else { return }
        var msg = conversation.messages[idx]
        let records = calls.map { call -> ToolCallRecord in
            var call = call
            if let binding = binding(for: call.name, in: catalog, fromText: fromText) {
                call.serverID = binding.serverID
                call.serverName = binding.serverName
                call.toolName = binding.tool.name
            }
            return call
        }
        let round = ToolRound(content: msg.content, reasoning: msg.reasoning, reasoningDuration: msg.reasoningDuration,
                              calls: records, usage: msg.usage, stats: liveMeter.finalStats())
        msg.toolRounds = (msg.toolRounds ?? []) + [round]
        msg.content = ""
        msg.reasoning = nil
        msg.reasoningDuration = nil
        msg.usage = nil
        conversation.messages[idx] = msg
        liveAccumulator = StreamAccumulator()
        liveMeter = GenerationMeter()
        liveReAct = nil
        liveGeneration = nil
        streamIsReasoning = false
        streamReasoningStartedAt = nil
        historyUsageCache = nil
        conversation.updatedAt = Date()
        saveNow()
    }

    /// Runs one round's calls one after another, which keeps approvals and side effects predictable.
    /// `fromText`: ReAct. Every call shows the card, whatever was stored for the tool: text can be an
    /// echo of tool output, so Always Allow, which is about structured calls, does not reach it.
    private func runCalls(_ callIDs: [String], messageID: UUID, catalog: MCPToolCatalog,
                          tools: ConversationToolServices, target: ReplyTarget, fromText: Bool) async {
        for callID in callIDs {
            guard isCurrent(messageID), !Task.isCancelled, let call = call(callID, in: messageID) else { return }
            // What never runs asks for no approval, and the model hears why.
            guard let arguments = ToolArguments.parse(call.arguments) else {
                let reason = ToolArguments.problem(call.arguments)
                setResult(ToolCallResult(status: .notCalled, text: ToolResultText.malformed(reason: reason, raw: call.arguments)),
                          for: callID, in: messageID)
                continue
            }
            guard let binding = binding(for: call.name, in: catalog, fromText: fromText) else {
                setResult(ToolCallResult(status: .notCalled, text: ToolResultText.unknownTool(call.name)), for: callID, in: messageID)
                continue
            }
            guard let server = currentServer(for: binding, tools: tools) else {
                setResult(ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff), for: callID, in: messageID)
                continue
            }
            let allowance = tools.allowance(binding)
            let folderOnCard = tools.builtInFolderPath()
            if allowance != .always || fromText {
                replyPhase = .awaitingApproval
                let approval = PendingToolApproval(
                    id: callID,
                    serverName: binding.serverName,
                    serverDetail: Self.serverDetail(server, binding: binding, arguments: arguments, tools: tools),
                    toolName: binding.tool.name,
                    description: binding.tool.description,
                    parameters: binding.tool.inputSchema.prettyJSONText,
                    arguments: arguments.isEmpty ? "{}" : JSONValue.object(arguments).prettyJSONText,
                    definitionChanged: allowance == .changed,
                    readFromText: fromText,
                    asksEveryTime: BuiltInTools.asksEveryTime(binding),
                    isBuiltIn: binding.serverID == BuiltInTools.serverID
                )
                let decision = await requestApproval(approval, messageID: messageID)
                guard isCurrent(messageID) else { return }
                switch decision {
                case .deny:
                    setResult(ToolCallResult(status: .denied, text: ToolResultText.denied), for: callID, in: messageID)
                    continue
                case .cancelled:
                    return
                case .alwaysAllow:
                    // The card has no such button for these.
                    if approval.offersAlwaysAllow { tools.setAlwaysAllowed(binding) }
                case .allowOnce:
                    break
                }
                // Switched off while the card was up, or the card's folder is no longer the shared
                // one: its Allow can no longer mean anything.
                let folderMoved = BuiltInTools.readsFolder(binding) && tools.builtInFolderPath() != folderOnCard
                guard !folderMoved, currentServer(for: binding, tools: tools) != nil else {
                    setResult(ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff), for: callID, in: messageID)
                    continue
                }
            }
            // Saved first: a crash from here on may have run the tool.
            updateCall(callID, in: messageID) { $0.startedAt = Date() }
            saveNow()
            replyPhase = .runningTool(binding.tool.name)
            activeCallID = callID
            let budget = ContextBudget.toolResultBudget(
                configured: server.effectiveMaxResultCharacters,
                limit: tools.contextLimit(target.provider, target.model),
                used: contextUsage().tokens
            )
            var result = await tools.host.call(binding, arguments: arguments,
                                               timeout: server.effectiveCallTimeout,
                                               maxCharacters: budget)
            // Stop has already written a result.
            guard isCurrent(messageID) else { return }
            activeCallID = nil
            // The runner reads Settings for itself, after the check above: if the folder moved in
            // between, what came back is not from the folder that was approved, and it stops here.
            if BuiltInTools.readsFolder(binding), tools.builtInFolderPath() != folderOnCard {
                result = ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff)
            }
            setResult(result, for: callID, in: messageID)
        }
    }

    /// The server as it is now, if this conversation may still use the tool: the catalog dates from
    /// the start of the reply, and a loop of always-allowed calls has no other point to stop at.
    private func currentServer(for binding: MCPToolBinding, tools: ConversationToolServices) -> MCPServerConfig? {
        tools.enabledServers(conversation.settings).first {
            $0.id == binding.serverID && !$0.disabledTools.contains(binding.tool.name)
        }
    }

    private static func serverDetail(_ server: MCPServerConfig, binding: MCPToolBinding, arguments: [String: JSONValue],
                                     tools: ConversationToolServices) -> String {
        if server.kind == MCPServerConfig.kindBuiltIn {
            return BuiltInTools.approvalDetail(toolName: binding.tool.name, arguments: arguments, folderPath: tools.builtInFolderPath())
        }
        return server.kind == MCPServerConfig.kindHTTP ? server.urlHost : "Local command: \(server.command)"
    }

    private func call(_ callID: String, in messageID: UUID) -> ToolCallRecord? {
        guard let idx = index(of: messageID) else { return nil }
        return (conversation.messages[idx].toolRounds ?? []).lazy.flatMap(\.calls).first { $0.id == callID }
    }

    private func updateCall(_ callID: String, in messageID: UUID, _ change: (inout ToolCallRecord) -> Void) {
        guard let idx = index(of: messageID), var rounds = conversation.messages[idx].toolRounds else { return }
        for r in rounds.indices {
            if let c = rounds[r].calls.firstIndex(where: { $0.id == callID }) {
                change(&rounds[r].calls[c])
                conversation.messages[idx].toolRounds = rounds
                return
            }
        }
    }

    private func setResult(_ result: ToolCallResult, for callID: String, in messageID: UUID) {
        updateCall(callID, in: messageID) { $0.result = result }
        conversation.updatedAt = Date()
        saveNow()
    }

    /// Waits for the card's buttons. Approval never times out: the user may be away, and nothing is
    /// sent while it waits.
    private func requestApproval(_ approval: PendingToolApproval, messageID: UUID) async -> ToolApprovalDecision {
        guard isCurrent(messageID), !Task.isCancelled else { return .cancelled }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = approval
            tools?.approvalNeeded()
        }
    }

    /// Idempotent: a late press after Stop finds nothing to answer. A button names its call, so a
    /// double press cannot answer the card that took the first one's place.
    func answerApproval(_ decision: ToolApprovalDecision, for callID: String? = nil) {
        guard callID == nil || callID == pendingApproval?.id, let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: decision)
    }

    /// After Stop every call has a result, so the file and the next request are never left with a
    /// dangling one. `startedAt` tells whether the tool may have run.
    private func resolveUnfinishedCalls(_ messageID: UUID) {
        guard let idx = index(of: messageID), var rounds = conversation.messages[idx].toolRounds else { return }
        let now = Date()
        for r in rounds.indices {
            for c in rounds[r].calls.indices where rounds[r].calls[c].result == nil {
                let started = rounds[r].calls[c].startedAt
                rounds[r].calls[c].result = ToolCallResult(
                    status: .cancelled,
                    text: started == nil ? ToolResultText.notRun : ToolResultText.interrupted,
                    duration: started.map { now.timeIntervalSince($0) }
                )
            }
        }
        conversation.messages[idx].toolRounds = rounds
    }

    /// Context tokens in use (ContextBudget.usage), the in-flight reply's live count included.
    /// While streaming, the history part is computed once per reply: the status strip
    /// re-renders on every message flush (20 Hz), and a long conversation or a large text
    /// attachment would otherwise be re-estimated each time.
    /// `idleToolDefinitionTokens`: what the next request's `tools` would cost, while nothing streams.
    func contextUsage(idleToolDefinitionTokens: Int = 0) -> ContextUsage {
        let history: ContextUsage
        if let id = streamingMessageID {
            let inFlight = index(of: id).map { conversation.messages[$0] }
            let rounds = inFlight?.toolRounds ?? []
            let key = HistoryUsageKey(inFlightID: id, messageCount: conversation.messages.count,
                                      systemPrompt: conversation.settings.systemPrompt,
                                      toolRoundCount: rounds.count,
                                      resolvedCallCount: rounds.reduce(0) { $0 + $1.calls.filter { $0.result != nil }.count },
                                      toolDefinitionTokens: inFlight?.toolDefinitionTokens ?? 0)
            if let cached = historyUsageCache, cached.key == key {
                history = cached.usage
            } else {
                history = ContextBudget.usage(messages: conversation.messages, systemPrompt: key.systemPrompt, inFlightID: id,
                                              toolDefinitionTokens: key.toolDefinitionTokens)
                historyUsageCache = (key, history)
            }
        } else {
            historyUsageCache = nil
            history = ContextBudget.usage(messages: conversation.messages, systemPrompt: conversation.settings.systemPrompt,
                                          toolDefinitionTokens: idleToolDefinitionTokens)
        }
        guard let live = liveGeneration, live.tokens > 0 else { return history }
        return ContextUsage(tokens: history.tokens + live.tokens, isEstimated: history.isEstimated || live.isEstimated)
    }

    private struct HistoryUsageKey: Equatable {
        let inFlightID: UUID
        let messageCount: Int
        let systemPrompt: String
        let toolRoundCount: Int
        let resolvedCallCount: Int
        let toolDefinitionTokens: Int
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
        if liveReAct != nil {
            // Stop and Lock come through here too: raw Action lines never reach the message.
            liveReAct?.feed(acc.content, generation: acc.contentGeneration)
            let live = liveReAct?.live(acc.content)
            msg.content = live?.text ?? ""
            msg.reactThought = live?.thought
        } else {
            msg.content = acc.content
        }
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
        // Stop and close both come through here. A cancelled Task does not resume a continuation.
        answerApproval(.cancelled)
        resolveUnfinishedCalls(messageID)
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
            // "None" was sent and thinking came anyway (an empty <think></think> does not count).
            let message = conversation.messages[idx]
            let thoughts = [message.reasoning] + (message.toolRounds ?? []).map(\.reasoning)
            if liveSendsThinkingOff, message.thinkingOffNotAccepted != true,
               thoughts.contains(where: { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                conversation.messages[idx].thinkingOffIgnored = true
                conversation.messages[idx].thinkingOffServerKind = liveThinkingOffServerKind?.rawValue
            }
        }
        liveSendsThinkingOff = false
        liveThinkingOffServerKind = nil
        liveGeneration = nil
        replyPhase = nil
        activeCallID = nil
        roundStartedAt = nil
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
