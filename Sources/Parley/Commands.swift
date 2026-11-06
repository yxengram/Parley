import AppKit
import SwiftUI
import ParleyCore

// Menu bar commands. Conversation and message items act on the conversation shown in the
// main window (published by ChatView through `focusedSceneValue(\.activeSession)`).
//
// Shortcuts were chosen to avoid the system's: ⌘⌫ is left to text editing (the sidebar list
// handles Delete itself via onDeleteCommand), ⌘; stays Check Spelling.

struct FileCommands: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Chat") {
            openWindow(id: "main")
            appState.showNewChatSheet = true
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Open Conversation File…") {
            openWindow(id: "main")
            appState.openConversationFile()
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Lock All Encrypted Conversations") {
            appState.lockAll()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

/// Acts on the conversation selected in the sidebar (also when it is not loaded yet).
struct ConversationCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Conversation") {
            ConversationMenuContent(appState: appState)
        }
    }
}

private struct ConversationMenuContent: View {
    let appState: AppState

    var body: some View {
        let entry = appState.entry(id: appState.selection)
        let open = entry.flatMap { appState.session(for: $0.id) }
        let streaming = open?.isStreaming ?? false
        let locked = (entry?.isEncrypted ?? false) && open == nil
        let encrypted = (entry?.isEncrypted ?? false) || (open?.isEncrypted ?? false)

        Button("Rename…") {
            if let entry { appState.sidebarRequest = .rename(entry.id) }
        }
        .disabled(entry == nil || locked)

        Button("Conversation Settings…") {
            if let open { appState.conversationSettingsRequest = open.id }
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(open == nil)

        Button("Tools…") {
            if let open { appState.toolsPopoverRequest = open.id }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(open == nil || streaming || appState.settings.mcpServers.isEmpty)

        Button("Fork from Last Message") {
            if let open, let last = open.conversation.messages.indices.last {
                appState.fork(open, through: last)
            }
        }
        .disabled(open == nil || streaming || (open?.conversation.messages.isEmpty ?? true))

        Divider()

        if encrypted {
            Button("Change Password…") {
                if let open { appState.sidebarRequest = .changePassword(open.id) }
            }
            .disabled(open == nil || streaming)
            Button("Remove Encryption…") {
                if let open { appState.sidebarRequest = .removeEncryption(open.id) }
            }
            .disabled(open == nil || streaming)
            Button("Lock") {
                if let entry { appState.lock(entry.id) }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(open == nil)
        } else {
            Button("Encrypt…") {
                if let entry { appState.sidebarRequest = .encrypt(entry.id) }
            }
            .disabled(entry == nil || streaming)
        }

        Divider()

        Button("Reveal in Finder") {
            if let entry { appState.revealInFinder(entry) }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(entry == nil)

        Button("Remove from List") {
            if let entry { appState.removeFromList(entry) }
        }
        .disabled(entry == nil)

        Button("Move to Trash…") {
            if let entry { appState.sidebarRequest = .moveToTrash(entry.id) }
        }
        .disabled(entry == nil)
    }
}

struct MessageCommands: Commands {
    let appState: AppState
    @FocusedValue(\.activeSession) private var session

    var body: some Commands {
        CommandMenu("Message") {
            MessageMenuContent(appState: appState, session: session)
        }
    }
}

private struct MessageMenuContent: View {
    let appState: AppState
    let session: ConversationSession?

    var body: some View {
        let messages = session?.conversation.messages ?? []
        let busy = session?.isStreaming ?? true
        let lastReply = messages.last(where: { $0.role == .assistant && !$0.visibleText.isEmpty })

        Button("Copy Last Reply") {
            if let lastReply { Pasteboard.copy(lastReply.visibleText) }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(lastReply == nil)

        Button("Regenerate Last Reply") {
            guard let session, let i = messages.indices.last, messages[i].role == .assistant else { return }
            // A reply that ran tools asks first (ChatView).
            if (messages[i].toolRounds ?? []).isEmpty {
                session.regenerate(messageAt: i, settings: appState.settings)
            } else {
                appState.regenerateRequest = session.id
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(busy || messages.last?.role != .assistant)

        Button("Get Reply") {
            session?.startReply(settings: appState.settings)
        }
        .disabled(busy || messages.last?.role != .user)

        Button("Edit Last Message") {
            guard let session, let i = session.lastUserMessageIndex else { return }
            session.beginEdit(messageAt: i)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(busy || session?.lastUserMessageIndex == nil)

        Divider()

        Button("Stop Generating") {
            session?.stop()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!(session?.isStreaming ?? false))
    }
}

struct HelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Parley Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSAttributedString(
            string: "A private chat client for OpenAI-compatible APIs.\nParley only contacts the API endpoints and MCP servers you configure. No telemetry; conversations stay in files on this Mac.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
