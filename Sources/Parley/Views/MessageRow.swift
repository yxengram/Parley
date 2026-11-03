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
    }

    private var isUser: Bool { message.role == .user }
    private var isLast: Bool { index == messageCount - 1 }
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
        .accessibilityAction(named: "Copy") { copy() }
        .accessibilityAction(named: isUser ? "Edit and Resend" : "Regenerate") {
            guard !conversationBusy else { return }
            if isUser { actions.edit(index) } else { requestRegenerate() }
        }
        .accessibilityAction(named: "Fork from Here") {
            guard !conversationBusy else { return }
            actions.fork(index)
        }
        .accessibilityAction(named: "Roll Back to Here") {
            guard !conversationBusy, !isLast else { return }
            confirmRollback = true
        }
        .confirmationDialog("Roll back to this message?", isPresented: $confirmRollback) {
            Button("Roll Back", role: .destructive) { actions.rollback(index) }
        } message: {
            Text(laterCount == 1
                 ? "The message after this one will be deleted from the conversation."
                 : "The \(laterCount) messages after this one will be deleted from the conversation.")
        }
        .confirmationDialog("Regenerate this reply?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { actions.regenerate(index) }
        } message: {
            Text(laterCount == 1
                 ? "This reply and the message after it will be replaced."
                 : "This reply and the \(laterCount) messages after it will be replaced.")
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
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if editState == .editing {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ThinkingDisclosure(
                    reasoning: reasoning,
                    duration: message.reasoningDuration,
                    isThinking: isReasoningNow,
                    isStreaming: isStreamingThis,
                    startedAt: thinkingStartedAt
                )
            }

            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments, alignment: .leading)
            }

            if !message.content.isEmpty {
                MarkdownView(text: message.content)
            } else if isStreamingThis && (message.reasoning ?? "").isEmpty {
                WaitingIndicator(startedAt: message.createdAt, progress: promptProgress, serverKind: serverKind)
            }

            if !isStreamingThis, message.error == nil, let note = Self.finishNote(message, maxTokens: maxTokens) {
                Label(note, systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = message.error {
                let partial = !message.content.isEmpty || !(message.reasoning ?? "").isEmpty
                let presentation = ErrorPresentation.make(error, providerName: providerName, baseURL: providerBaseURL,
                                                          serverKind: serverKind, partialReply: partial)
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
                        .foregroundStyle(.secondary)
                    Button {
                        requestRegenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
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
            Image(systemName: "sparkles")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message.model ?? "Assistant")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Assistant, \(message.model ?? "unknown model"), \(message.createdAt.formatted(date: .omitted, time: .shortened))"))
    }

    @ViewBuilder
    private var footer: some View {
        if showUsage, let line = Self.footerText(usage: message.usage, stats: message.stats) {
            Text(line)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.8))
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
                ? "The reply ran out of room in the context while thinking. Start a new chat, fork from an earlier message or roll back; a thinking budget (Conversation Settings, ⌘I) leaves room to answer."
                : "The reply ran out of tokens while thinking. Raise Max tokens, lower the reasoning effort or set a thinking budget (Conversation Settings, ⌘I), then regenerate."
        }
        return contextFull
            ? "The reply was cut off at the end of the context (or the server's own output limit). Start a new chat, fork from an earlier message or roll back to make room."
            : "The reply was cut off at the token limit (Max tokens)."
    }

    /// "1184 prompt · 236 completion · 1420 total tokens · 42.3 tok/s · 0.21 s to first token".
    /// Without server usage, the chunk count stands in, marked "≈".
    static func footerText(usage: TokenUsage?, stats: GenerationStats?) -> String? {
        var groups: [String] = []
        if let usage {
            let parts: [String] = [
                usage.promptTokens.map { "\($0) prompt" },
                usage.completionTokens.map { "\($0) completion" },
                usage.totalTokens.map { "\($0) total" },
            ].compactMap { $0 }
            if !parts.isEmpty { groups.append(parts.joined(separator: " · ") + " tokens") }
        }
        if let stats {
            let approx = (stats.isEstimated ?? false) ? "≈" : ""
            if groups.isEmpty, let n = stats.completionTokens {
                groups.append("\(approx)\(n) tokens")
            }
            if let r = stats.tokensPerSecond {
                groups.append(approx + TokenFormat.rate(r) + " tok/s")
            }
            if let t = stats.timeToFirstToken {
                groups.append(TokenFormat.seconds(t) + " to first token")
            }
        }
        return groups.isEmpty ? nil : groups.joined(separator: " · ")
    }

    // MARK: Actions

    private func copy() {
        Pasteboard.copy(message.content)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// Regenerating the last reply needs no confirmation; an earlier one drops later messages.
    private func requestRegenerate() {
        guard !conversationBusy else { return }
        if isLast { actions.regenerate(index) } else { confirmRegenerate = true }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy Message") { copy() }
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            Button("Copy Thinking") { Pasteboard.copy(reasoning) }
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
            Button(isLast ? "Regenerate" : "Regenerate…") { requestRegenerate() }
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
        HStack(spacing: 2) {
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
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
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
                    if let progress {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(Self.statusText(progress: progress, elapsed: elapsed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if progress == nil, serverKind == .strata, elapsed >= Self.loadingHintAfter {
                    Text("Strata may be loading the model or reading a long prompt; a first reply after a pause can take a few minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Reading the prompt: 42% of 40,960 tokens (30,000 cached) · 12 s" or "Waiting for response… 12 s".
    static func statusText(progress: PromptProgress?, elapsed: TimeInterval) -> String {
        let seconds = elapsed >= 2 ? " · \(Int(elapsed)) s" : ""
        guard let progress else {
            return "Waiting for response…" + (elapsed >= 2 ? " \(Int(elapsed)) s" : "")
        }
        let cached = progress.cached > 0 ? " (\(TokenFormat.grouped(progress.cached)) cached)" : ""
        return "Reading the prompt: \(Int((progress.fraction * 100).rounded(.down)))% of \(TokenFormat.grouped(progress.total)) tokens\(cached)" + seconds
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
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let status = presentation.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let raw = presentation.raw, raw != presentation.title {
                        Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                if showDetails, let raw = presentation.raw {
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if presentation.suggestsSettings {
                    SettingsLink { Text("Settings…") }
                        .controlSize(.small)
                }
                if let retry {
                    Button(action: retry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.18)))
        .help(raw)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(presentation.title)")
    }
}

private struct ActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
