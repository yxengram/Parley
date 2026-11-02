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
        }
        .sheet(isPresented: $state.showNewChatSheet) {
            NewChatSheet()
                .environment(appState)
        }
        .alert(item: $state.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        // Only open links the user clicked, and only for web/mail schemes.
        .environment(\.openURL, OpenURLAction { url in
            let scheme = url.scheme?.lowercased() ?? ""
            return ["http", "https", "mailto"].contains(scheme) ? .systemAction : .discarded
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
        ContentUnavailableView {
            Label("No conversation selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Pick a conversation in the sidebar or start a new one.")
        } actions: {
            Button("New Chat") { appState.showNewChatSheet = true }
                .keyboardShortcut(.defaultAction)
        }
    }
}
