import SwiftUI
import ParleyCore

struct MessageRow: View, Equatable {
    struct Actions {
        var rollback: (Int) -> Void
        var fork: (Int) -> Void
        /// Staged edit: puts the message in the composer; history changes only when it is sent.
        var edit: (Int) -> Void
        var regenerate: (Int) -> Void
        /// Requests a reply to a trailing user message.
        var getReply: () -> Void
        /// The buttons of the approval card.
        var answerApproval: (String, ToolApprovalDecision) -> Void = { _, _ in }
    }

    enum EditState: Equatable {
        case none
        /// This message is in the composer being edited.
        case editing
        /// A later message that sending the edit will remove.
        case replaced
    }

    let message: Message
    let index: Int
    let messageCount: Int
    let isStreamingThis: Bool
    let isReasoningNow: Bool
    let thinkingStartedAt: Date?
    /// True while any reply in this conversation is streaming: history edits are disabled.
    let conversationBusy: Bool
    let showUsage: Bool
    let editState: EditState
    let providerName: String?
    let providerBaseURL: String?
    /// What the app knows about the server (for a few server-specific hints).
    var serverKind: InferenceServerKind? = nil
    /// How far the server has read the prompt, while this reply waits for its first token.
    var promptProgress: PromptProgress? = nil
    /// The conversation's Max Tokens (nil when off), to tell a capped reply from a full context.
    var maxTokens: Int? = nil
    /// An earlier reply (the nearest one) carries the same "None (no thinking)" note: this one
    /// gets the short form, the full text is in its help tag.
    var repeatsThinkingOffNote = false
    /// What this reply is doing while it streams.
    var replyPhase: ConversationSession.ReplyPhase? = nil
    /// When this reply's current request went out.
    var roundStartedAt: Date? = nil
    /// The tool call of this reply waiting for the user.
    var pendingApproval: PendingToolApproval? = nil
    /// The tool call of this reply running now.
    var activeCallID: String? = nil
    let actions: Actions

    @ViewState private var isHovering = false
    @ViewState private var confirmRollback = false
    @ViewState private var confirmRegenerate = false
    @ViewState private var copied = false

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.index == rhs.index
            && lhs.messageCount == rhs.messageCount
            && lhs.isStreamingThis == rhs.isStreamingThis
            && lhs.isReasoningNow == rhs.isReasoningNow
            && lhs.thinkingStartedAt == rhs.thinkingStartedAt
            && lhs.conversationBusy == rhs.conversationBusy
            && lhs.showUsage == rhs.showUsage
            && lhs.editState == rhs.editState
            && lhs.providerName == rhs.providerName
            && lhs.providerBaseURL == rhs.providerBaseURL
            && lhs.serverKind == rhs.serverKind
            && lhs.promptProgress == rhs.promptProgress
            && lhs.maxTokens == rhs.maxTokens
            && lhs.repeatsThinkingOffNote == rhs.repeatsThinkingOffNote
            && lhs.replyPhase == rhs.replyPhase
            && lhs.roundStartedAt == rhs.roundStartedAt
            && lhs.pendingApproval == rhs.pendingApproval
            && lhs.activeCallID == rhs.activeCallID
    }

    private var isUser: Bool { message.role == .user }
    private var isLast: Bool { index == messageCount - 1 }
    private var hasToolRounds: Bool { !(message.toolRounds ?? []).isEmpty }
    /// Cuts the note's edge the same way on every launch (`hashValue` would not).
    private var noteSeed: Int { Int(message.id.uuid.0) &* 251 &+ Int(message.id.uuid.1) }
    private var laterCount: Int { max(0, messageCount - index - 1) }

    var body: some View {
        Group {
            if isUser { userBody } else { assistantBody }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .opacity(editState == .replaced ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy")) { copy() }
        .accessibilityAction(named: isUser ? Text("Edit and Resend") : Text("Regenerate")) {
            guard !conversationBusy else { return }
            if isUser { actions.edit(index) } else { requestRegenerate() }
        }
        .accessibilityAction(named: Text("Fork from Here")) {
            guard !conversationBusy else { return }
            actions.fork(index)
        }
        .accessibilityAction(named: Text("Roll Back to Here")) {
            guard !conversationBusy, !isLast else { return }
            confirmRollback = true
        }
        .confirmationDialog("Roll back to this message?", isPresented: $confirmRollback) {
            Button("Roll Back", role: .destructive) { actions.rollback(index) }
        } message: {
            laterCount == 1
                ? Text("The message after this one will be deleted from the conversation.")
                : Text("The \(laterCount) messages after this one will be deleted from the conversation.")
        }
        .confirmationDialog("Regenerate this reply?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { actions.regenerate(index) }
        } message: {
            Text(Self.regenerateWarning(laterCount: laterCount, ranTools: hasToolRounds))
        }
    }

    // MARK: User

    private var userBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            if showsActionBar {
                actionBar
                    .padding(.top, 2)
                    .transition(.opacity)
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments, alignment: .trailing)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .fontDesign(.default)
                        .foregroundStyle(Hideout.ink)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .paperCard(Hideout.peach, seed: noteSeed, radius: 14)
                        .overlay {
                            if editState == .editing {
                                WobblyRect(seed: noteSeed, radius: 14)
                                    .strokeBorder(Hideout.ember, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 3]))
                            }
                        }
                        .help(Text(message.createdAt, format: .dateTime.weekday().hour().minute()))
                }
                if let error = message.error {
                    ErrorCallout(presentation: ErrorPresentation.make(error, providerName: providerName, baseURL: providerBaseURL, serverKind: serverKind), raw: ErrorPresentation.displayText(error), retry: nil, busy: conversationBusy)
                }
                if isLast && !conversationBusy {
                    Button(action: actions.getReply) {
                        Label("Get Reply", systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(TagButtonStyle())
                    .help("Ask the model to answer this message")
                }
            }
        }
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if showsActionBar {
                        actionBar.transition(.opacity)
                    }
                }

            if let rounds = message.toolRounds, !rounds.isEmpty {
                ToolRoundsView(rounds: rounds, replyInProgress: isStreamingThis, activeCallID: activeCallID,
                               pendingApproval: pendingApproval, answer: actions.answerApproval)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ThinkingDisclosure(
                    reasoning: reasoning,
                    duration: message.reasoningDuration,
                    isThinking: isReasoningNow,
                    isStreaming: isStreamingThis,
                    startedAt: thinkingStartedAt
                )
            }

            if let thought = message.reactThought, !thought.isEmpty {
                // The model wrote this as text, so it stays collapsed, also while streaming.
                ThinkingDisclosure(reasoning: thought, duration: nil, isThinking: false, isStreaming: false)
            }

            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments, alignment: .leading)
            }

            if !message.content.isEmpty {
                MarkdownView(text: message.content)
            } else if isStreamingThis && (message.reasoning ?? "").isEmpty {
                if replyPhase == nil || replyPhase == .generating {
                    WaitingIndicator(startedAt: roundStartedAt ?? message.createdAt, progress: promptProgress, serverKind: serverKind)
                } else if case .connecting(let servers) = replyPhase {
                    HStack(spacing: 6) {
                        FirefliesIndicator()
                        Text(verbatim: Self.startingText(servers))
                            .foregroundStyle(Hideout.inkSoft)
                    }
                }
            }

            if !isStreamingThis, message.error == nil, let note = Self.finishNote(message, maxTokens: maxTokens) {
                Label(note, systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isStreamingThis, let note = Self.thinkingOffNote(message, repeated: repeatsThinkingOffNote) {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Self.thinkingOffNote(message) ?? note)
            }

            if !isStreamingThis {
                ForEach(message.toolNotes ?? [], id: \.self) { note in
                    Label(Self.toolNoteText(note), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(note.detail ?? "")
                }
            }

            if let error = message.error {
                let partial = !message.content.isEmpty || !(message.reasoning ?? "").isEmpty || hasToolRounds
                let presentation = ErrorPresentation.make(error, providerName: providerName, baseURL: providerBaseURL,
                                                          serverKind: serverKind, partialReply: partial)
                    .naming(toolDefinitionTokens: message.toolDefinitionTokens, in: error)
                ErrorCallout(
                    presentation: presentation,
                    raw: ErrorPresentation.displayText(error),
                    retry: presentation.retryable ? { requestRegenerate() } : nil,
                    busy: conversationBusy
                )
            } else if !message.isComplete && !isStreamingThis {
                HStack(spacing: 8) {
                    Text("Stopped before the reply finished.")
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                    Button {
                        requestRegenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TagButtonStyle())
                    .disabled(conversationBusy)
                }
            }

            footer
        }
    }

    private var showsActionBar: Bool {
        guard !isStreamingThis else { return false }
        #if DEBUG
        if SnapshotHarness.forcedHoverMessageID == message.id { return true }
        #endif
        return isHovering
    }

    private var header: some View {
        HStack(spacing: 5) {
            LanternMark(size: 16)
            (message.model.map { Text(verbatim: $0) } ?? Text("Assistant"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Hideout.inkSoft)
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(Hideout.inkFaint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeader)
    }

    private var accessibilityHeader: Text {
        let time = message.createdAt.formatted(date: .omitted, time: .shortened)
        if let model = message.model { return Text("Assistant, \(model), \(time)") }
        return Text("Assistant, unknown model, \(time)")
    }

    @ViewBuilder
    private var footer: some View {
        // While the reply runs, an earlier round's figures would read as the reply's.
        let usage = isStreamingThis ? message.usage : message.usage ?? message.toolRounds?.last(where: { $0.usage != nil })?.usage
        let stats = isStreamingThis ? message.stats : message.latestStats
        if showUsage, let line = Self.footerText(usage: usage, stats: stats, toolRounds: isStreamingThis ? 0 : message.toolRounds?.count ?? 0) {
            Text(line)
                .font(.caption2)
                .foregroundStyle(Hideout.inkFaint)
        }
    }

    /// Why a reply that the server ended early is short: finish_reason "length" means it hit
    /// max_tokens or the end of the context (Strata shortens max_tokens to the room left). Fewer
    /// completion tokens than `maxTokens`, or no cap at all, means the context ran out.
    static func finishNote(_ message: Message, maxTokens: Int? = nil) -> String? {
        guard message.role == .assistant, message.stats?.finishReason == "length" else { return nil }
        // A chunk count (estimated) may be short of the real count: it does not prove a full context.
        let completion = message.usage?.completionTokens
            ?? (message.stats?.isEstimated == true ? nil : message.stats?.completionTokens)
        let contextFull = maxTokens.map { cap in completion.map { $0 < cap } ?? false } ?? true
        if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(message.reasoning ?? "").isEmpty {
            return contextFull
                ? String(localized: "The reply ran out of room in the context while thinking. Start a new chat, fork from an earlier message or roll back; a thinking budget (Conversation Settings, ⌘I) leaves room to answer.")
                : String(localized: "The reply ran out of tokens while thinking. Raise Max tokens, lower the reasoning effort (or choose None) or, on Strata, set a thinking budget (Conversation Settings, ⌘I), then regenerate.")
        }
        return contextFull
            ? String(localized: "The reply was cut off at the end of the context (or the server's own output limit). Start a new chat, fork from an earlier message or roll back to make room.")
            : String(localized: "The reply was cut off at the token limit (Max tokens).")
    }

    enum ThinkingOffNoteKind: Equatable {
        /// The server refused the field; the reply used its default thinking.
        case notAccepted
        /// The field was sent, thinking came back anyway.
        case ignored
    }

    /// Which "None (no thinking)" note a reply carries. None for a reply that failed before any
    /// text arrived: there is no reply for the note to describe.
    static func thinkingOffNoteKind(_ message: Message) -> ThinkingOffNoteKind? {
        guard message.role == .assistant else { return nil }
        if message.error != nil, message.content.isEmpty, (message.reasoning ?? "").isEmpty { return nil }
        if message.thinkingOffNotAccepted == true { return .notAccepted }
        if message.thinkingOffIgnored == true { return .ignored }
        return nil
    }

    /// Why a reply asked for with "None (no thinking)" still thought: the server refused the field
    /// (the reply was requested again without it) or ignored it. Never claims thinking was off.
    /// `repeated`: the reply before already says the same, so the short form. The hint names the
    /// server kind that wrote the reply (stored with the note), not the conversation's current one.
    static func thinkingOffNote(_ message: Message, repeated: Bool = false) -> String? {
        switch thinkingOffNoteKind(message) {
        case nil:
            return nil
        case .notAccepted:
            return repeated
                ? String(localized: "“None” was not accepted again, so this reply also used the default thinking.")
                : String(localized: "This server did not accept “None (no thinking)”, so this reply used its default thinking.")
        case .ignored:
            if repeated { return String(localized: "“None” was ignored again: this reply also contains thinking.") }
            switch message.thinkingOffServerKind.flatMap(InferenceServerKind.init(rawValue:)) {
            case .lmStudio:
                return String(localized: "This server or model ignored “None (no thinking)”: the reply still contains thinking. LM Studio may offer a thinking switch in this model's settings.")
            case .llamaCpp, .vLLM:
                return String(localized: "This server or model ignored “None (no thinking)”: the reply still contains thinking. The model's chat template may not support turning it off.")
            default:
                return String(localized: "This server or model ignored “None (no thinking)”: the reply still contains thinking.")
            }
        }
    }

    /// "name: summary" with MCPError's known summary in the interface language.
    static func shownServerFailure(_ detail: String) -> String {
        guard let colon = detail.range(of: ": ") else { return MCPErrorText.shown(detail) }
        return String(detail[..<colon.upperBound]) + MCPErrorText.shown(String(detail[colon.upperBound...]))
    }

    /// The text of a note about tools. A kind a later version added shows its `detail`.
    static func toolNoteText(_ note: ToolNote) -> String {
        switch note.kind {
        case ToolNote.toolsNotAccepted:
            return String(localized: "The model's server did not accept tools, so this reply was written without them.")
        case ToolNote.toolsNotOffered:
            return String(localized: "Tools were not offered: Strata runs this model in its runtime mode, which ignores them. Use a native model in Strata.")
        case ToolNote.serverUnavailable:
            // The detail is the server's stored (English) error summary; its system sentences are
            // shown in the interface language.
            let stored = note.detail.map(Self.shownServerFailure) ?? String(localized: "A server")
            let detail = stored.trimmingCharacters(in: CharacterSet(charactersIn: ".。 \n"))
            return String(localized: "\(detail). Its tools were not offered.")
        case ToolNote.roundLimit:
            return String(localized: "Reached the limit of \(note.detail ?? "") tool rounds, so the model was asked to answer without more tools. Change the limit in Settings > MCP.")
        case ToolNote.callsNotRun:
            return String(localized: "The reply ended inside a tool call, so it was not run.")
        case ToolNote.emptyAfterTools:
            return String(localized: "The model wrote nothing after the tool results.")
        default:
            return note.detail ?? ""
        }
    }

    /// "Starting filesystem…", while a first start may take minutes (a first `npx` downloads).
    static func startingText(_ servers: [String]) -> String {
        String(localized: "Starting \(servers.map(ToolDisplay.visible).joined(separator: ", "))…")
    }

    /// For each message, whether the nearest earlier reply carries the same thinking-off note.
    static func repeatsThinkingOffNotes(_ messages: [Message]) -> [Bool] {
        var previous: ThinkingOffNoteKind?
        return messages.map { message in
            guard message.role == .assistant else { return false }
            let kind = thinkingOffNoteKind(message)
            defer { previous = kind }
            return kind != nil && kind == previous
        }
    }

    /// "1184 prompt · 236 completion · 1420 total tokens · 42.3 tok/s · 0.21 s to first token".
    /// Without server usage, the chunk count stands in, marked "≈".
    static func footerText(usage: TokenUsage?, stats: GenerationStats?, toolRounds: Int = 0) -> String? {
        var groups: [String] = []
        if let usage {
            // Counts as plain digits: an Int in String(localized:) would get grouping separators.
            let parts: [String] = [
                usage.promptTokens.map { String(localized: "\(String($0)) prompt") },
                usage.completionTokens.map { String(localized: "\(String($0)) completion") },
                usage.totalTokens.map { String(localized: "\(String($0)) total") },
            ].compactMap { $0 }
            if !parts.isEmpty { groups.append(String(localized: "\(parts.joined(separator: " · ")) tokens")) }
        }
        if let stats {
            let approx = (stats.isEstimated ?? false) ? "≈" : ""
            if groups.isEmpty, let n = stats.completionTokens {
                groups.append(String(localized: "\(approx)\(String(n)) tokens"))
            }
            if let r = stats.tokensPerSecond {
                // tok/s is a unit, like MB: not translated.
                groups.append(approx + TokenFormat.rate(r) + " tok/s")
            }
            if let t = stats.timeToFirstToken {
                groups.append(String(localized: "\(TokenFormat.seconds(t)) to first token"))
            }
        }
        if toolRounds > 0 {
            groups.append(toolRounds == 1 ? String(localized: "1 tool round") : String(localized: "\(toolRounds) tool rounds"))
        }
        return groups.isEmpty ? nil : groups.joined(separator: " · ")
    }

    // MARK: Actions

    private func copy() {
        Pasteboard.copy(message.visibleText)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// Regenerating the last reply needs no confirmation; an earlier one drops later messages, and
    /// one that ran tools may run them again.
    private func requestRegenerate() {
        guard !conversationBusy else { return }
        if isLast && !hasToolRounds { actions.regenerate(index) } else { confirmRegenerate = true }
    }

    /// Whole sentences per case, so the order can change in a translation.
    static func regenerateWarning(laterCount: Int, ranTools: Bool) -> String {
        switch (laterCount, ranTools) {
        case (0, false):
            return String(localized: "This reply will be replaced.")
        case (1, false):
            return String(localized: "This reply and the message after it will be replaced.")
        case (_, false):
            return String(localized: "This reply and the \(laterCount) messages after it will be replaced.")
        case (0, true):
            return String(localized: "This reply will be replaced. This reply ran tools. Their effects are not undone, and the model may run them again.")
        case (1, true):
            return String(localized: "This reply and the message after it will be replaced. This reply ran tools. Their effects are not undone, and the model may run them again.")
        case (_, true):
            return String(localized: "This reply and the \(laterCount) messages after it will be replaced. This reply ran tools. Their effects are not undone, and the model may run them again.")
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy Message") { copy() }
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            Button("Copy Thinking") { Pasteboard.copy(reasoning) }
        }
        if let thought = message.reactThought, !thought.isEmpty {
            Button("Copy Thought") { Pasteboard.copy(thought) }
        }
        if let rounds = message.toolRounds, !rounds.isEmpty {
            Button("Copy Tool Calls") { Pasteboard.copy(ToolDisplay.copyText(rounds)) }
        }
        Divider()
        if isUser {
            Button("Edit & Resend") { actions.edit(index) }
                .disabled(conversationBusy)
            if isLast {
                Button("Get Reply") { actions.getReply() }
                    .disabled(conversationBusy)
            }
        } else {
            Button(isLast && !hasToolRounds ? "Regenerate" : "Regenerate…") { requestRegenerate() }
                .disabled(conversationBusy)
        }
        Button("Fork from Here") { actions.fork(index) }
            .disabled(conversationBusy)
        if !isLast {
            Divider()
            Button("Roll Back to Here…", role: .destructive) { confirmRollback = true }
                .disabled(conversationBusy)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            ActionButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                copy()
            }
            if isUser {
                ActionButton(systemImage: "pencil", help: "Edit & resend") {
                    actions.edit(index)
                }
                .disabled(conversationBusy)
            } else {
                ActionButton(systemImage: "arrow.clockwise", help: "Regenerate") {
                    requestRegenerate()
                }
                .disabled(conversationBusy)
            }
            ActionButton(systemImage: "arrow.triangle.branch", help: "Fork from here") {
                actions.fork(index)
            }
            .disabled(conversationBusy)
            if !isLast {
                ActionButton(systemImage: "arrow.uturn.backward", help: "Roll back to here") {
                    confirmRollback = true
                }
                .disabled(conversationBusy)
            }
        }
    }
}

/// Before the first token: how far the server has read the prompt when it says so (Strata,
/// llama.cpp with return_progress), else how long the request has been waiting.
struct WaitingIndicator: View {
    let startedAt: Date
    let progress: PromptProgress?
    let serverKind: InferenceServerKind?

    /// From here on, a Strata server that sends nothing at all is probably loading the model.
    static let loadingHintAfter: TimeInterval = 10

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    FirefliesIndicator()
                    Text(Self.statusText(progress: progress, elapsed: elapsed))
                        .foregroundStyle(Hideout.inkSoft)
                        .monospacedDigit()
                }
                if progress == nil, serverKind == .strata, elapsed >= Self.loadingHintAfter {
                    Text("Strata may be loading the model or reading a long prompt; a first reply after a pause can take a few minutes.")
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Reading the prompt: 42% of 40,960 tokens (30,000 cached) · 12 s" or "Waiting for response… 12 s".
    static func statusText(progress: PromptProgress?, elapsed: TimeInterval) -> String {
        let elapsedSeconds = Int(elapsed)
        guard let progress else {
            return elapsed >= 2 ? String(localized: "Waiting for response… \(elapsedSeconds) s") : String(localized: "Waiting for response…")
        }
        let percent = Int((progress.fraction * 100).rounded(.down))
        let total = TokenFormat.grouped(progress.total)
        let reading = progress.cached > 0
            ? String(localized: "Reading the prompt: \(percent)% of \(total) tokens (\(TokenFormat.grouped(progress.cached)) cached)")
            : String(localized: "Reading the prompt: \(percent)% of \(total) tokens")
        return elapsed >= 2 ? String(localized: "\(reading) · \(elapsedSeconds) s") : reading
    }
}

/// A failed request: readable title, server detail, Retry and (when relevant) Settings.
private struct ErrorCallout: View {
    let presentation: ErrorPresentation
    let raw: String
    let retry: (() -> Void)?
    let busy: Bool
    @ViewState private var showDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Hideout.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Hideout.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Hideout.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let status = presentation.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(Hideout.inkSoft)
                    }
                    if let raw = presentation.raw, raw != presentation.title {
                        Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .underline()
                            .foregroundStyle(Hideout.danger)
                    }
                }
                if showDetails, let raw = presentation.raw {
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .fontDesign(.monospaced)
                        .foregroundStyle(Hideout.inkSoft)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if presentation.suggestsSettings {
                    SettingsLink { Text("Settings…") }
                        .buttonStyle(TagButtonStyle())
                }
                if let retry {
                    Button(action: retry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TagButtonStyle())
                    .disabled(busy)
                }
            }
        }
        .padding(12)
        .noticeCard(fill: Hideout.dangerWash, edge: Hideout.danger)
        .help(raw)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(presentation.title)")
    }
}

private struct ActionButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(PaperRoundButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small round paper button. Opaque, unlike `RoundIconButtonStyle`, because it sits over text;
/// when disabled only its icon fades, so the paper stays solid.
private struct PaperRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        @ViewState private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let active = hovering && isEnabled
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Hideout.ink : Hideout.inkSoft)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(active ? Hideout.paperDeep : Hideout.card)
                        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                }
                .overlay(Circle().strokeBorder(Hideout.line))
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}
