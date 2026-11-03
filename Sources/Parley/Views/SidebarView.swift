import SwiftUI
import ParleyCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    @ViewState private var renameTarget: ConversationSession?
    @ViewState private var passwordTarget: PasswordSheet.Target?
    @ViewState private var removeEncryptionTarget: ConversationSession?
    @ViewState private var deleteTarget: LibraryEntry?
    @ViewState private var showEncryptedNotice = false
    @ViewState private var query = ""

    var body: some View {
        @Bindable var state = appState
        let groups = groupedEntries
        List(selection: $state.selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        SidebarRow(entry: entry, dateStyle: group.dateStyle)
                            .tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        // Right-click menu for the clicked row; double-click or Return renames.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let entry = appState.entry(id: id) {
                contextMenu(for: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = appState.entry(id: id) {
                rename(entry)
            }
        }
        // Delete / ⌘⌫ while the list has focus: the same "Move to Trash" confirmation.
        .onDeleteCommand {
            if let entry = appState.entry(id: appState.selection) { deleteTarget = entry }
        }
        .overlay {
            if appState.entries.isEmpty && !appState.isScanning {
                ContentUnavailableView {
                    Label("No conversations", systemImage: "bubble.left")
                } description: {
                    Text("Press ⌘N to start a new chat.")
                }
            } else if !query.isEmpty && groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
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
        .onChange(of: appState.sidebarRequest) { _, request in
            guard let request else { return }
            appState.sidebarRequest = nil
            handle(request)
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

        Button("Rename…") { rename(entry) }
            .disabled(locked)
        Button("Fork") {
            if let session, let last = session.conversation.messages.indices.last {
                appState.fork(session, through: last)
            }
        }
        .disabled(session == nil || streaming || (session?.conversation.messages.isEmpty ?? true))

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
        Button("Move to Trash…", role: .destructive) { deleteTarget = entry }
    }

    private func rename(_ entry: LibraryEntry) {
        guard !(entry.isEncrypted && appState.session(for: entry.id) == nil) else { return }
        Task {
            if let s = await ensureSession(entry) { renameTarget = s }
        }
    }

    private func handle(_ request: AppState.SidebarRequest) {
        switch request {
        case .rename(let id):
            if let entry = appState.entry(id: id) { rename(entry) }
        case .encrypt(let id):
            guard let entry = appState.entry(id: id) else { return }
            Task {
                if let s = await ensureSession(entry) { passwordTarget = .init(session: s, mode: .encrypt) }
            }
        case .changePassword(let id):
            if let s = appState.session(for: id) { passwordTarget = .init(session: s, mode: .change) }
        case .removeEncryption(let id):
            removeEncryptionTarget = appState.session(for: id)
        case .moveToTrash(let id):
            deleteTarget = appState.entry(id: id)
        }
    }

    // MARK: Grouping and search

    struct DateGroup {
        let title: String
        let dateStyle: SidebarRow.DateStyle
        var entries: [LibraryEntry]
    }

    /// Today / Yesterday / Previous 7 Days / Older, newest first. Search matches titles of plain
    /// and unlocked conversations only (locked ones have no title in memory).
    private var groupedEntries: [DateGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = appState.sortedEntries.filter { entry in
            guard !q.isEmpty else { return true }
            return appState.displayTitle(for: entry)?.localizedStandardContains(q) ?? false
        }
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var groups: [DateGroup] = [
            DateGroup(title: "Today", dateStyle: .time, entries: []),
            DateGroup(title: "Yesterday", dateStyle: .time, entries: []),
            DateGroup(title: "Previous 7 Days", dateStyle: .weekday, entries: []),
            DateGroup(title: "Older", dateStyle: .date, entries: []),
        ]
        for entry in entries {
            let date = appState.sortDate(for: entry)
            let i: Int
            if calendar.isDateInToday(date) || date > now { i = 0 }
            else if calendar.isDateInYesterday(date) { i = 1 }
            else if date >= weekAgo { i = 2 }
            else { i = 3 }
            groups[i].entries.append(entry)
        }
        return groups.filter { !$0.entries.isEmpty }
    }

    private func ensureSession(_ entry: LibraryEntry) async -> ConversationSession? {
        if let s = appState.session(for: entry.id) { return s }
        return await appState.loadPlain(entry)
    }
}

struct SidebarRow: View {
    enum DateStyle { case time, weekday, date }

    @Environment(AppState.self) private var appState
    let entry: LibraryEntry
    var dateStyle: DateStyle = .date

    var body: some View {
        let session = appState.session(for: entry.id)
        let title = appState.displayTitle(for: entry)
        let date = appState.sortDate(for: entry)
        let url = session?.fileURL ?? entry.url
        let locked = entry.isEncrypted && session == nil
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
                HStack(spacing: 0) {
                    dateText(date)
                    // Locked conversations show their folder, which helps tell them apart
                    // without decrypting anything.
                    if locked || !appState.settings.isInDefaultDirectory(url) {
                        Text(" · " + url.deletingLastPathComponent().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if session?.isStreaming == true {
                ProgressView().controlSize(.small)
            }
            if entry.isEncrypted || session?.isEncrypted == true {
                Image(systemName: session == nil ? "lock.fill" : "lock.open")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(session == nil ? "Encrypted, locked" : "Encrypted, unlocked")
                    .accessibilityLabel(session == nil ? "Locked" : "Unlocked")
            }
        }
        .padding(.vertical, 2)
        .help(abbreviated(url.path))
    }

    @ViewBuilder
    private func dateText(_ date: Date) -> some View {
        switch dateStyle {
        case .time: Text(date, format: .dateTime.hour().minute())
        case .weekday: Text(date, format: .dateTime.weekday(.wide))
        case .date: Text(date, format: .dateTime.day().month(.abbreviated).year())
        }
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
