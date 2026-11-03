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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Chat")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("Automatic (from first message)"))
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(abbreviated(directoryPath))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 250, alignment: .trailing)
                                .help(directoryPath)
                            Button("Choose…", action: chooseDirectory)
                        }
                    }
                    if isCloudSyncedLocation(directoryPath) {
                        Label(cloudSyncWarning, systemImage: "icloud")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Toggle("Encrypt this conversation", isOn: $encrypt)
                        .toggleStyle(.switch)
                    if encrypt {
                        PasswordFields(password: $password, confirm: $confirm)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
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
        }
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
                try await appState.createConversation(title: title, directory: dir, password: pw)
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
