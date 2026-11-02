import SwiftUI
import ParleyCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    @ViewState private var renameTarget: ConversationSession?
    @ViewState private var passwordTarget: PasswordSheet.Target?
    @ViewState private var removeEncryptionTarget: ConversationSession?
    @ViewState private var deleteTarget: LibraryEntry?
    @ViewState private var showEncryptedNotice = false

    var body: some View {
        @Bindable var state = appState
        List(selection: $state.selection) {
            ForEach(appState.sortedEntries) { entry in
                SidebarRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { contextMenu(for: entry) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if appState.entries.isEmpty && !appState.isScanning {
                ContentUnavailableView {
                    Label("No conversations", systemImage: "bubble.left")
                } description: {
                    Text("Press ⌘N to start a new chat.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    appState.showNewChatSheet = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Open Conversation File…") { appState.openConversationFile() }
                    Button("Refresh List") { appState.reloadLibrary() }
                    Divider()
                    Button("Lock All Encrypted") { appState.lockAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.showNewChatSheet = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")
            }
        }
        .sheet(item: $renameTarget) { session in
            RenameSheet(title: session.conversation.title) { newTitle in
                session.rename(newTitle)
            }
        }
        .sheet(item: $passwordTarget, onDismiss: {
            // Shown only after the sheet is gone, so the alert is never hidden behind it.
            if showEncryptedNotice {
                showEncryptedNotice = false
                appState.notice = AppState.encryptedOverwriteNotice
            }
        }) { target in
            PasswordSheet(target: target, onSuccess: { newlyEncrypted in
                if newlyEncrypted { showEncryptedNotice = true }
            })
            .environment(appState)
        }
        .confirmationDialog(
            "Remove encryption?",
            isPresented: Binding(get: { removeEncryptionTarget != nil }, set: { if !$0 { removeEncryptionTarget = nil } }),
            presenting: removeEncryptionTarget
        ) { session in
            Button("Remove Encryption", role: .destructive) {
                appState.removeEncryption(from: session)
            }
        } message: { _ in
            Text("The conversation will be saved as a plain, unencrypted JSON file that anyone with access to the file can read.")
        }
        .confirmationDialog(
            "Move this conversation file to the Trash?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { entry in
            Button("Move to Trash", role: .destructive) {
                appState.moveToTrash(entry)
            }
        } message: { entry in
            Text(entry.url.lastPathComponent)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        let session = appState.session(for: entry.id)
        let locked = entry.isEncrypted && session == nil
        let streaming = session?.isStreaming ?? false

        Button("Rename…") {
            Task {
                if let s = await ensureSession(entry) {
                    renameTarget = s
                }
            }
        }
        .disabled(locked)

        if entry.isEncrypted || (session?.isEncrypted ?? false) {
            Button("Change Password…") {
                if let session { passwordTarget = .init(session: session, mode: .change) }
            }
            .disabled(session == nil || streaming)
            Button("Remove Encryption…") {
                removeEncryptionTarget = session
            }
            .disabled(session == nil || streaming)
            Button("Lock") {
                appState.lock(entry.id)
            }
            .disabled(session == nil)
        } else {
            Button("Encrypt…") {
                Task {
                    if let s = await ensureSession(entry) {
                        passwordTarget = .init(session: s, mode: .encrypt)
                    }
                }
            }
            .disabled(streaming)
        }

        Divider()
        Button("Reveal in Finder") { appState.revealInFinder(entry) }
        Button("Remove from List") { appState.removeFromList(entry) }
        Divider()
        Button("Delete File…", role: .destructive) { deleteTarget = entry }
    }

    private func ensureSession(_ entry: LibraryEntry) async -> ConversationSession? {
        if let s = appState.session(for: entry.id) { return s }
        return await appState.loadPlain(entry)
    }
}

private struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    let entry: LibraryEntry

    var body: some View {
        let session = appState.session(for: entry.id)
        let title = appState.displayTitle(for: entry)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Encrypted conversation")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(appState.sortDate(for: entry), format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if session?.isStreaming == true {
                ProgressView().controlSize(.small)
            }
            if entry.isEncrypted || session?.isEncrypted == true {
                Image(systemName: session == nil ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
                    .help(session == nil ? "Encrypted, locked" : "Encrypted, unlocked")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var title: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Conversation").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(title)
        dismiss()
    }
}
