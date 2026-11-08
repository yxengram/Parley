import AppKit
import SwiftUI
import ParleyCore

struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @ViewState private var title = ""
    @ViewState private var directoryPath = ""
    @ViewState private var encrypt = false
    @ViewState private var password = ""
    @ViewState private var confirm = ""
    @ViewState private var isWorking = false
    @ViewState private var error: String?
    /// The servers ticked here; starts as those marked "Use in new chats".
    @ViewState private var toolServers: Set<UUID> = []
    @FocusState private var titleFocused: Bool

    private var servers: [MCPServerConfig] { appState.settings.mcpServers.filter(\.isEnabled) }
    private static let unscrolledServers = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Chat")
                .lettered(26)
                .foregroundStyle(Hideout.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 22)
                .padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailsCard
                    encryptionCard
                    if !servers.isEmpty {
                        toolsCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)
            }
            // With many servers the list scrolls, or Create would fall off a laptop's screen.
            .scrollDisabled(servers.count <= Self.unscrolledServers)
            .frame(height: servers.count <= Self.unscrolledServers ? nil : 540)
            .fixedSize(horizontal: false, vertical: servers.count <= Self.unscrolledServers)

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .safetyNotice(.danger)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 8) {
                if isWorking { HideoutSpinner() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(TagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Create", action: create)
                    .buttonStyle(TagButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || (encrypt && !PasswordFields.isValid(password: password, confirm: confirm)))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
        .frame(width: 500)
        .onAppear {
            if directoryPath.isEmpty { directoryPath = appState.settings.defaultDirectoryURL.path }
            toolServers = Set(servers.filter(\.useInNewChats).map(\.id))
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                // Drawn here, as the composer's is: AppKit's placeholder is a cold grey below 4.5:1.
                ZStack(alignment: .leading) {
                    if title.isEmpty {
                        Text("Automatic (from first message)")
                            .foregroundStyle(Hideout.inkSoft)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("Title", text: $title, prompt: Text(verbatim: ""))
                        .labelsHidden()
                        .focused($titleFocused)
                }
                .paperField(focused: titleFocused, seed: 23)
            } label: {
                // The field carries the label for VoiceOver; the visible one would repeat it.
                Text("Title").accessibilityHidden(true)
            }
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(abbreviated(directoryPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Hideout.inkSoft)
                        .frame(maxWidth: 250, alignment: .trailing)
                        .help(directoryPath)
                    Button("Choose…", action: chooseDirectory)
                        .buttonStyle(TagButtonStyle())
                }
            }
            if isCloudSyncedLocation(directoryPath) {
                Label(cloudSyncWarning, systemImage: "icloud")
                    .safetyNotice(.caution)
            }
        }
        .labeledContentStyle(PaperRowStyle())
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stitchedCard(seed: 24)
        .overlay(alignment: .top) {
            WashiTape(color: Hideout.marigold, width: 66, height: 17, angle: -2).offset(y: -8)
        }
    }

    private var encryptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $encrypt) {
                Text("Encrypt this conversation")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            if encrypt {
                PasswordFields(password: $password, confirm: $confirm)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stitchedCard(seed: 25)
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools")
                .lettered(18)
                .foregroundStyle(Hideout.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(servers) { server in
                Toggle(isOn: Binding(
                    get: { toolServers.contains(server.id) },
                    set: { on in
                        if on { toolServers.insert(server.id) } else { toolServers.remove(server.id) }
                    }
                )) {
                    Text(verbatim: ToolDisplay.visible(server.name))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stitchedCard(seed: 26)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directoryPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            directoryPath = url.path
        }
    }

    private func create() {
        guard !isWorking else { return }
        if encrypt && !PasswordFields.isValid(password: password, confirm: confirm) { return }
        isWorking = true
        error = nil
        let pw = encrypt ? password : nil
        let dir = URL(fileURLWithPath: directoryPath, isDirectory: true)
        Task {
            do {
                try await appState.createConversation(title: title, directory: dir, password: pw,
                                                       mcpServerIDs: servers.map(\.id).filter(toolServers.contains))
                password = ""
                confirm = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}

func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

let cloudSyncWarning = "This folder may be synced to a cloud service (iCloud Drive, Dropbox, OneDrive, Google Drive…). Unencrypted conversations stored here can leave this Mac."

/// Rough check for folders that may be uploaded by a sync service: iCloud Drive's
/// "Desktop & Documents", iCloud Drive itself, File Provider mounts in ~/Library/CloudStorage
/// (Dropbox, OneDrive, Google Drive, Box…), and anything the system reports as ubiquitous.
func isCloudSyncedLocation(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let home = NSHomeDirectory()
    let expanded = (path as NSString).expandingTildeInPath
    let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    let synced = [
        "\(home)/Desktop", "\(home)/Documents",
        "\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage",
    ]
    for p in [expanded, resolved] where synced.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
        return true
    }
    // Nearest existing folder (a new chat's folder may not exist yet).
    var url = URL(fileURLWithPath: resolved, isDirectory: true)
    while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
        url = url.deletingLastPathComponent()
    }
    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
    return values?.isUbiquitousItem == true
}

// Private on purpose: other surfaces define their own helpers, and these must not collide.
private enum SafetyTone { case caution, danger }

private extension View {
    /// A warning or an error on its own flat strip. Exact wording, no decoration.
    func safetyNotice(_ tone: SafetyTone) -> some View {
        let edge = tone == .danger ? Hideout.danger : Hideout.caution
        return self
            .font(.callout.weight(.medium))
            .foregroundStyle(edge)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .noticeCard(fill: tone == .danger ? Hideout.dangerWash : Hideout.cautionWash, edge: edge, radius: 8)
    }
}


private extension View {
    /// A text field on a paper tag; its edge shows where the typing goes.
    func paperField(fill: Color = Hideout.paperDeep, focused: Bool, seed: Int = 5) -> some View {
        self
            .textFieldStyle(.plain)
            .foregroundStyle(Hideout.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .paperCard(fill, seed: seed, radius: 9, shadow: false)
            .overlay {
                WobblyRect(seed: seed, radius: 9)
                    .strokeBorder(focused ? Hideout.ember : Hideout.line, lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}


/// A label beside its field, for a stitched card.
private struct PaperRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .frame(width: 120, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
