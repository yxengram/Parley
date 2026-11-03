import AppKit
import SwiftUI
import ParleyCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .frame(width: 700, height: 460)
                .tabItem { Label("Providers", systemImage: "server.rack") }
            GeneralSettingsView()
                .frame(width: 560, height: 500)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
    }
}

// MARK: - Providers

private struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var appState
    @ViewState private var selectedID: UUID?
    @ViewState private var confirmDelete = false

    var body: some View {
        let settings = appState.settings
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(settings.providers) { p in
                        HStack {
                            Text(p.name.isEmpty ? "Untitled" : p.name)
                                .lineLimit(1)
                            Spacer()
                            if p.id == settings.defaultProviderID {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 4) {
                    Button {
                        let p = Provider(name: "New Provider", baseURL: "http://localhost:1234/v1")
                        settings.providers.append(p)
                        if settings.defaultProviderID == nil { settings.defaultProviderID = p.id }
                        selectedID = p.id
                    } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .help("Add Provider")
                    .accessibilityLabel("Add Provider")
                    Button {
                        confirmDelete = true
                    } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                    .disabled(selectedID == nil)
                    .help("Remove Provider")
                    .accessibilityLabel("Remove Provider")
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 8)
            }
            .padding([.leading, .top, .bottom], 20)
            .frame(width: 220)

            Group {
                if let id = selectedID, settings.providers.contains(where: { $0.id == id }) {
                    ProviderEditor(providerID: id)
                        .id(id)
                } else {
                    ContentUnavailableView("Select a provider", systemImage: "server.rack")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedID == nil { selectedID = settings.defaultProviderID ?? settings.providers.first?.id }
        }
        .confirmationDialog("Delete this provider?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("Its API key will be removed from the Keychain.")
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        let settings = appState.settings
        try? KeychainStore.deleteAPIKey(for: id)
        settings.providers.removeAll { $0.id == id }
        appState.modelsByProvider[id] = nil
        if settings.defaultProviderID == id { settings.defaultProviderID = settings.providers.first?.id }
        selectedID = settings.providers.first?.id
    }
}

private struct ProviderEditor: View {
    @Environment(AppState.self) private var appState
    let providerID: UUID

    @ViewState private var apiKeyDraft = ""
    @ViewState private var storedKey = ""
    @ViewState private var keyError: String?
    @ViewState private var keySaved = false
    @ViewState private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, running, ok(Int), failed(String)
    }

    private var index: Int? { appState.settings.providers.firstIndex { $0.id == providerID } }

    var body: some View {
        if let index {
            form(index: index)
        }
    }

    @ViewBuilder
    private func form(index: Int) -> some View {
        @Bindable var settings = appState.settings
        let provider = settings.providers[index]
        Form {
            Section {
                TextField("Name", text: $settings.providers[index].name)
                TextField("Base URL", text: $settings.providers[index].baseURL, prompt: Text("http://192.168.1.20:1234/v1"))
                    .textContentType(.URL)
                if let warning = Self.urlWarning(provider.baseURL) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                TextField("Default model", text: $settings.providers[index].defaultModel, prompt: Text("optional"))
            } footer: {
                Text("The base URL includes the version path; /chat/completions and /models are appended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    SecureField("API key", text: $apiKeyDraft, prompt: Text("none (local servers)"))
                        .onSubmit(saveKey)
                    Button(keySaved ? "Saved" : "Save Key", action: saveKey)
                        .disabled(apiKeyDraft == storedKey)
                }
                if let keyError {
                    Text(keyError).foregroundStyle(.red).font(.caption)
                }
            } footer: {
                Text("Stored in your login Keychain (not synced). Never written to preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection", action: test)
                        .disabled(testStatus == .running)
                    switch testStatus {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .ok(let n):
                        Label("Connected, \(n) model\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                    Spacer()
                }
                LabeledContent("New chats") {
                    if settings.defaultProviderID == providerID {
                        Label("Default provider", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { settings.defaultProviderID = providerID }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadKey)
        // Closing Settings or switching providers must not silently drop a typed key.
        // (Not for a provider that was just deleted: its key must stay removed.)
        .onDisappear {
            guard appState.settings.providers.contains(where: { $0.id == providerID }) else { return }
            if apiKeyDraft != storedKey { saveKey() }
        }
    }

    static func urlWarning(_ base: String) -> String? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else {
            return "Enter a full URL such as http://localhost:1234/v1."
        }
        guard scheme == "http" || scheme == "https" else { return "Only http and https URLs are supported." }
        if scheme == "http" && !ChatClient.isLocalHost(host) {
            return "Traffic is unencrypted."
        }
        return nil
    }

    /// Keychain is read only when the editor opens for a provider.
    private func loadKey() {
        do {
            let key = try KeychainStore.apiKey(for: providerID) ?? ""
            storedKey = key
            apiKeyDraft = key
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.setAPIKey(apiKeyDraft, for: providerID)
            storedKey = apiKeyDraft
            keyError = nil
            keySaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
        } catch {
            keyError = error.localizedDescription
        }
    }

    /// Tests exactly what chats will use: the key is saved first and read back from the Keychain.
    private func test() {
        guard let index else { return }
        let provider = appState.settings.providers[index]
        if apiKeyDraft != storedKey {
            saveKey()
            if keyError != nil {
                testStatus = .failed("The API key could not be saved to the Keychain.")
                return
            }
        }
        let key: String?
        do {
            key = try KeychainStore.apiKey(for: provider.id)
        } catch {
            testStatus = .failed(error.localizedDescription)
            return
        }
        testStatus = .running
        Task {
            do {
                let client = try ChatClient(baseURL: provider.baseURL, apiKey: key)
                let models = try await client.listModels()
                appState.storeModels(models, for: provider)
                testStatus = .ok(models.count)
            } catch {
                testStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Conversations") {
                LabeledContent {
                    HStack {
                        Label(settings.defaultDirectoryURL.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .help(abbreviated(settings.defaultDirectoryPath))
                        Button("Choose…", action: chooseDirectory)
                    }
                } label: {
                    Text("Default folder")
                    Text(abbreviated(settings.defaultDirectoryPath))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Reveal in Finder") {
                        let url = settings.defaultDirectoryURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Use Default Location") {
                        appState.changeDefaultDirectory(to: AppSettings.builtInDefaultDirectory)
                    }
                    .disabled(settings.defaultDirectoryPath == AppSettings.builtInDefaultDirectory.path)
                }
                if isCloudSyncedLocation(settings.defaultDirectoryPath) {
                    Label(cloudSyncWarning, systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Each conversation is saved as one JSON file named by a random ID. New chats can choose their own folder. Desktop and Documents may be synced by iCloud, and folders in ~/Library/CloudStorage by Dropbox, OneDrive or Google Drive; the default location in Application Support is not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Display") {
                Toggle("Show token usage under replies", isOn: $settings.showTokenUsage)
            }

            Section("Privacy") {
                Label("Parley only contacts the API endpoints you configure. No telemetry.", systemImage: "hand.raised.fill")
                Text("API keys live in the Keychain. Encrypted conversations are decrypted only in memory. The Copy buttons (and copying from the message box) keep text off Universal Clipboard; selected text copied with ⌘C elsewhere uses the normal clipboard, which Handoff may share with your other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = appState.settings.defaultDirectoryURL
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            appState.changeDefaultDirectory(to: url)
        }
    }
}
