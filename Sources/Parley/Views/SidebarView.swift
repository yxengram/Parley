import SwiftUI
import ParleyCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var state = appState
        let groups = groupedEntries
        VStack(spacing: 0) { wallHeader(query: $state.sidebarQuery); conversationList(groups, selection: $state.selection) }
            .background(WallBackground())
            .foregroundStyle(Hideout.wallInk)
            // initial: ⌘F may have just brought the sidebar back.
            .onChange(of: appState.sidebarSearchFocusPending, initial: true) { _, pending in
                guard pending else { return }
                appState.sidebarSearchFocusPending = false
                // A sidebar that has just appeared has no field in the window yet.
                DispatchQueue.main.async { searchFocused = true }
            }
    }

    private func wallHeader(query: Binding<String>) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                WindowDragArea()
                // The cord hangs just below the traffic lights.
                Bunting().padding(.top, 34)
                HStack(spacing: 6) {
                    Spacer()
                    Button { appState.showNewChatSheet = true } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(RoundIconButtonStyle(size: 28, onWall: true))
                    .help("New Chat (⌘N)")
                    Button(action: appState.toggleSidebar) {
                        Label("Hide Sidebar", systemImage: "sidebar.left")
                    }
                    .buttonStyle(RoundIconButtonStyle(size: 28, onWall: true))
                    .help("Hide Sidebar (⌃⌘S)")
                }
                .padding(.top, 5)
                .padding(.trailing, 10)
            }
            .frame(height: 76)

            Text("Parley")
                .lettered(30)
                .foregroundStyle(Hideout.wallInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Hideout.inkSoft)
                    .accessibilityHidden(true)
                TextField("Search", text: query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Hideout.ink)
                    .focused($searchFocused)
                    .onExitCommand { query.wrappedValue = ""; searchFocused = false }
                if !query.wrappedValue.isEmpty {
                    Button { query.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Hideout.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .font(.system(size: 13, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .paperCard(Hideout.tag, seed: 3, radius: 9)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func conversationList(_ groups: [DateGroup], selection: Binding<UUID?>) -> some View {
        List(selection: selection) {
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.entries) { entry in
                        SidebarRow(entry: entry, dateStyle: group.dateStyle, isSelected: appState.selection == entry.id,
                                   listFocused: listFocused)
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(group.title)
                        .lettered(15)
                        .foregroundStyle(Hideout.wallInkSoft)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .scrollContentBackground(.hidden)
        .background(ListSelectionHighlightRemover())
        // Right-click menu for the clicked row; double-click or Return renames.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let entry = appState.entry(id: id) {
                contextMenu(for: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first { appState.sidebarRequest = .rename(id) }
        }
        // Delete / ⌘⌫ while the list has focus: the same "Move to Trash" confirmation.
        .onDeleteCommand {
            if let id = appState.selection { appState.sidebarRequest = .moveToTrash(id) }
        }
        .overlay {
            if appState.entries.isEmpty && !appState.isScanning {
                VStack(spacing: 6) {
                    Text("The wall is bare")
                        .lettered(20)
                    Text("Press ⌘N to start a new chat.")
                        .font(.callout)
                        .foregroundStyle(Hideout.wallInkSoft)
                }
                .foregroundStyle(Hideout.wallInk)
            } else if !appState.sidebarQuery.isEmpty && groups.isEmpty {
                VStack(spacing: 6) {
                    Text("Not on this wall")
                        .lettered(20)
                    Text("No conversation matches “\(appState.sidebarQuery)”.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Hideout.wallInkSoft)
                }
                .padding(.horizontal, 16)
                .foregroundStyle(Hideout.wallInk)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        let session = appState.session(for: entry.id)
        let locked = entry.isEncrypted && session == nil
        let streaming = session?.isStreaming ?? false

        Button("Rename…") { appState.sidebarRequest = .rename(entry.id) }
            .disabled(locked)
        Button("Fork") {
            if let session, let last = session.conversation.messages.indices.last {
                appState.fork(session, through: last)
            }
        }
        .disabled(session == nil || streaming || (session?.conversation.messages.isEmpty ?? true))

        if entry.isEncrypted || (session?.isEncrypted ?? false) {
            Button("Change Password…") { appState.sidebarRequest = .changePassword(entry.id) }
            .disabled(session == nil || streaming)
            Button("Remove Encryption…") { appState.sidebarRequest = .removeEncryption(entry.id) }
            .disabled(session == nil || streaming)
            Button("Lock") {
                appState.lock(entry.id)
            }
            .disabled(session == nil)
        } else {
            Button("Encrypt…") { appState.sidebarRequest = .encrypt(entry.id) }
            .disabled(streaming)
        }

        Divider()
        Button("Reveal in Finder") { appState.revealInFinder(entry) }
        Button("Remove from List") { appState.removeFromList(entry) }
        Divider()
        Button("Move to Trash…", role: .destructive) { appState.sidebarRequest = .moveToTrash(entry.id) }
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
        let q = appState.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = appState.sortedEntries.filter { entry in
            guard !q.isEmpty else { return true }
            return appState.displayTitle(for: entry)?.localizedStandardContains(q) ?? false
        }
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var groups: [DateGroup] = [
            DateGroup(title: String(localized: "Today"), dateStyle: .time, entries: []),
            DateGroup(title: String(localized: "Yesterday"), dateStyle: .time, entries: []),
            DateGroup(title: String(localized: "Previous 7 Days"), dateStyle: .weekday, entries: []),
            DateGroup(title: String(localized: "Older"), dateStyle: .date, entries: []),
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
}

/// The sheets and dialogs behind the Conversation menu and the sidebar's row menus, whatever asked
/// for them through `AppState.sidebarRequest`.
struct ConversationDialogs: ViewModifier {
    @Environment(AppState.self) private var appState

    @ViewState private var renameTarget: ConversationSession?
    @ViewState private var passwordTarget: PasswordSheet.Target?
    @ViewState private var removeEncryptionTarget: ConversationSession?
    @ViewState private var deleteTarget: LibraryEntry?
    @ViewState private var showEncryptedNotice = false

    func body(content: Content) -> some View {
        content
        // initial: a menu command chosen while the window was closed is waiting at reopen.
        .onChange(of: appState.sidebarRequest, initial: true) { _, request in
            guard let request else { return }
            appState.sidebarRequest = nil
            handle(request)
        }
        .sheet(item: $renameTarget) { session in
            RenameSheet(title: session.conversation.title) { newTitle in
                session.rename(newTitle)
            }
            .hideoutSheet()
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
            .hideoutSheet()
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
    var isSelected = false
    /// Whether arrow keys and Delete go to the list: without the system's highlight, the tag says so.
    var listFocused = false

    @ViewState private var hovering = false

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
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Encrypted conversation")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
                HStack(spacing: 0) {
                    dateText(date)
                    // Locked conversations show their folder, which helps tell them apart
                    // without decrypting anything.
                    if locked || !appState.settings.isInDefaultDirectory(url) {
                        Text(verbatim: " · " + url.deletingLastPathComponent().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(secondaryInk)
            }
            Spacer(minLength: 4)
            if session?.pendingApproval != nil {
                // Without this a background chat waits silently.
                Image(systemName: "hand.raised.fill")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Hideout.attention : Hideout.wallInk)
                    .help("Waiting for your approval of a tool call")
                    .accessibilityLabel("Waiting for approval")
            } else if session?.isStreaming == true {
                HideoutSpinner(color: isSelected ? Hideout.emberText : Hideout.wallInk)
            }
            if entry.isEncrypted || session?.isEncrypted == true {
                Image(systemName: session == nil ? "lock.fill" : "lock.open")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Hideout.brass : Hideout.wallInkSoft)
                    .help(session == nil ? "Encrypted, locked" : "Encrypted, unlocked")
                    .accessibilityLabel(session == nil ? "Locked" : "Unlocked")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                WobblyRect(seed: entry.id.hashValueStable, radius: 8)
                    .fill(Hideout.tag)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1.5)
                    .overlay {
                        if listFocused {
                            WobblyRect(seed: entry.id.hashValueStable, radius: 8)
                                .stroke(Hideout.ember, lineWidth: 1.5)
                        }
                    }
            } else if hovering {
                WobblyRect(seed: entry.id.hashValueStable, radius: 8)
                    .fill(Hideout.tag.opacity(0.35))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                WashiTape(color: Hideout.marigold, width: 34, height: 11, angle: 6)
                    .offset(x: 6, y: -3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(abbreviated(url.path))
    }

    private var primaryInk: Color { isSelected ? Hideout.ink : Hideout.wallInk }
    private var secondaryInk: Color { isSelected ? Hideout.inkSoft : Hideout.wallInkSoft }

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
            Text("Rename Conversation").lettered(22)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .foregroundStyle(Hideout.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .paperCard(Hideout.card, seed: 5, radius: 9)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(TagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .buttonStyle(TagButtonStyle(kind: .primary))
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

private extension UUID {
    /// A small seed that is the same on every launch (hashValue is not).
    var hashValueStable: Int { Int(uuid.0) &* 251 &+ Int(uuid.1) }
}
