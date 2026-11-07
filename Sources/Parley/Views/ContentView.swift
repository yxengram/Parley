import AppKit
import SwiftUI
import ParleyCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            DetailView()
                .sheet(item: $state.pendingLink) { link in
                    LinkConfirmationSheet(link: link, open: appState.confirmPendingLink) {
                        appState.pendingLink = nil
                    }
                }
        }
        .sheet(isPresented: $state.showNewChatSheet) {
            NewChatSheet()
                .environment(appState)
        }
        .alert(item: $state.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        // Every link click in this window ends here: nothing opens without LinkConfirmationSheet.
        .environment(\.openURL, OpenURLAction { url in
            appState.requestOpen(url) ? .handled : .discarded
        })
    }
}

/// The detail column: chat, unlock prompt, loader or placeholder.
struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let id = appState.selection, let entry = appState.entry(id: id) {
            if let session = appState.session(for: id) {
                ChatView(session: session)
                    .id(session.id)
            } else if entry.isEncrypted {
                UnlockView(entry: entry)
                    .id(entry.id)
            } else {
                PlainLoaderView(entry: entry)
                    .id(entry.id)
            }
        } else {
            EmptyDetailView()
        }
    }
}

private struct PlainLoaderView: View {
    @Environment(AppState.self) private var appState
    let entry: LibraryEntry

    var body: some View {
        Group {
            if let error = appState.loadErrors[entry.id] {
                ContentUnavailableView {
                    Label("Can't open conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        appState.loadErrors[entry.id] = nil
                        Task { await appState.loadPlain(entry) }
                    }
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry.id) {
            await appState.loadPlain(entry)
        }
    }
}

private struct EmptyDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let settings = appState.settings
        if settings.providers.isEmpty {
            ContentUnavailableView {
                Label("Set up a model provider", systemImage: "server.rack")
            } description: {
                Text("Add an OpenAI-compatible server, such as LM Studio on this Mac or an API on your network, in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(.borderedProminent)
                Button("New Chat") { appState.showNewChatSheet = true }
            }
        } else {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("No conversation selected")
                    .font(.title2.weight(.semibold))
                Text("Pick a conversation in the sidebar or start a new one.")
                    .foregroundStyle(.secondary)
                Button("New Chat") { appState.showNewChatSheet = true }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .padding(.top, 4)
                if let provider = settings.defaultProvider {
                    HStack(spacing: 4) {
                        Text("New chats use \(provider.name).")
                        SettingsLink { Text("Change in Settings…") }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
