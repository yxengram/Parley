import SwiftUI
import ParleyCore

struct MessageRow: View, Equatable {
    struct Actions {
        var rollback: (Int) -> Void
        var fork: (Int) -> Void
        var editAndResend: (Int) -> Void
        var regenerate: (Int) -> Void
    }

    let message: Message
    let index: Int
    let isStreamingThis: Bool
    let isReasoningNow: Bool
    /// True while any reply in this conversation is streaming: history edits are disabled.
    let conversationBusy: Bool
    let showUsage: Bool
    let actions: Actions

    @ViewState private var isHovering = false
    @ViewState private var confirmRollback = false
    @ViewState private var copied = false

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.index == rhs.index
            && lhs.isStreamingThis == rhs.isStreamingThis
            && lhs.isReasoningNow == rhs.isReasoningNow
            && lhs.conversationBusy == rhs.conversationBusy
            && lhs.showUsage == rhs.showUsage
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ThinkingDisclosure(
                    reasoning: reasoning,
                    duration: message.reasoningDuration,
                    isThinking: isReasoningNow,
                    isStreaming: isStreamingThis
                )
            }

            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments)
            }

            if !message.content.isEmpty {
                if isUser {
                    Text(message.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownView(text: message.content)
                }
            } else if isStreamingThis && (message.reasoning ?? "").isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for response…").foregroundStyle(.secondary)
                }
            }

            if let error = message.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .font(.callout)
                    if message.role == .assistant {
                        Button {
                            actions.regenerate(index)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .disabled(conversationBusy)
                    }
                }
            } else if message.role == .assistant && !message.isComplete && !isStreamingThis {
                Text("Stopped before the reply finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.secondary.opacity(0.07) : Color.clear)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                actionBar
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .confirmationDialog("Roll back to this message?", isPresented: $confirmRollback) {
            Button("Roll Back", role: .destructive) { actions.rollback(index) }
        } message: {
            Text("All messages after this one will be deleted from the conversation.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isUser ? "person.crop.circle.fill" : "sparkles")
                .foregroundStyle(isUser ? Color.accentColor : Color.purple)
            Text(isUser ? "You" : (message.model ?? "Assistant"))
                .font(.subheadline.weight(.semibold))
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if showUsage, message.role == .assistant, let usage = message.usage {
            let parts: [String] = [
                usage.promptTokens.map { "\($0) prompt" },
                usage.completionTokens.map { "\($0) completion" },
                usage.totalTokens.map { "\($0) total" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ") + " tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            ActionButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                Pasteboard.copy(message.content)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            if isUser {
                ActionButton(systemImage: "pencil", help: "Edit & resend") {
                    actions.editAndResend(index)
                }
                .disabled(conversationBusy)
            } else {
                ActionButton(systemImage: "arrow.clockwise", help: "Regenerate") {
                    actions.regenerate(index)
                }
                .disabled(conversationBusy)
            }
            ActionButton(systemImage: "arrow.triangle.branch", help: "Fork from here") {
                actions.fork(index)
            }
            .disabled(conversationBusy)
            ActionButton(systemImage: "arrow.uturn.backward", help: "Roll back to here") {
                confirmRollback = true
            }
            .disabled(conversationBusy)
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
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
