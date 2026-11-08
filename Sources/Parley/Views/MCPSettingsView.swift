import SwiftUI
import ParleyCore

// Settings > MCP. Opening this tab or selecting a server starts nothing: only Connect does. Arguments,
// URLs, environment values and headers are read from the secret store when an editor opens.

struct MCPSettingsView: View {
    @Environment(AppState.self) private var appState
    @ViewState private var selectedID: UUID?
    @ViewState private var confirmDelete = false
    @ViewState private var showImport = false
    @ViewState private var deleteError: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var settings = appState.settings
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(settings.mcpServers) { server in
                            SettingsListTag(isSelected: selectedID == server.id, id: server.id, listFocused: listFocused) {
                                HStack(spacing: 7) {
                                    PaperStatusDot(state: appState.mcpSnapshots[server.id]?.state ?? .stopped,
                                                   onWall: selectedID != server.id)
                                    Text(verbatim: server.name.isEmpty ? "Untitled" : ToolDisplay.line(server.name))
                                        .lineLimit(1)
                                    Spacer()
                                    if !server.isEnabled {
                                        Text("Off")
                                            .font(.caption)
                                            .foregroundStyle(selectedID == server.id ? Hideout.inkSoft : Hideout.wallInkSoft)
                                    }
                                }
                            }
                            .tag(server.id)
                            .settingsListRow()
                        }
                    }
                    .focused($listFocused)
                    .settingsListChrome()
                    .settingsKraftBoard(seed: 6)
                    HStack(spacing: 6) {
                        Button {
                            // Off until its first Save: until then it has no program to run, and no
                            // chat or sheet should offer it.
                            let server = MCPServerConfig(name: "New Server", isEnabled: false)
                            settings.mcpServers.append(server)
                            selectedID = server.id
                        } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                        .buttonStyle(RoundIconButtonStyle(size: 26))
                        .help("Add Server")
                        .accessibilityLabel("Add Server")
                        Button {
                            confirmDelete = true
                        } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                        .buttonStyle(RoundIconButtonStyle(size: 26))
                        .disabled(selectedID == nil)
                        .help("Remove Server")
                        .accessibilityLabel("Remove Server")
                        Spacer()
                        Button("Import…") { showImport = true }
                            .buttonStyle(TagButtonStyle())
                            .help("Paste a server config from another MCP client")
                    }
                    .padding(.top, 8)
                }
                .padding([.leading, .top], 20)
                .padding(.bottom, 12)
                .frame(width: 230)

                Group {
                    if let id = selectedID, settings.mcpServers.contains(where: { $0.id == id }) {
                        MCPServerEditor(serverID: id)
                            .id(id)
                    } else {
                        SettingsEmptyNote(
                            title: "No server selected",
                            systemImage: "wrench.and.screwdriver",
                            description: "Add a server, or import a config from another MCP client. Parley starts nothing and looks for nothing on its own."
                        )
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            SettingsStitchLine()
            HStack(spacing: 12) {
                Stepper(value: $settings.maxToolRounds, in: AppSettings.toolRoundsRange) {
                    Text("Tool rounds per reply: \(settings.maxToolRounds)")
                }
                .help("How many times in one reply the model may call tools before it has to answer.")
                if let deleteError {
                    SettingsNotice(.danger, deleteError).lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onAppear {
            if selectedID == nil { selectedID = settings.mcpServers.first?.id }
        }
        .confirmationDialog("Delete this server?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("It stops, and its arguments, URL, environment values and headers are removed from the Keychain.")
        }
        .sheet(isPresented: $showImport) {
            MCPImportSheet { id in
                if let id { selectedID = id }
            }
            .hideoutSheet()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SnapshotHarness.showMCPImportNotification)) { note in
            showImport = note.object as? Bool ?? true
        }
        .onReceive(NotificationCenter.default.publisher(for: SnapshotHarness.selectMCPServerNotification)) { note in
            selectedID = note.object as? UUID
        }
        #endif
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        do {
            try appState.deleteServer(id)
            selectedID = appState.settings.mcpServers.first?.id
            deleteError = nil
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// What the editor changes before Save: strings as typed, so Revert and the dirty check are simple.
struct MCPServerDraft: Equatable {
    struct Pair: Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var value = ""

        static func == (a: Pair, b: Pair) -> Bool { a.name == b.name && a.value == b.value }
    }

    var name = ""
    var kind = MCPServerConfig.kindStdio
    var command = ""
    /// One per line.
    var arguments = ""
    var workingDirectory = ""
    var url = ""
    var environment: [Pair] = []
    var headers: [Pair] = []
    var isEnabled = true
    var useInNewChats = false
    var callTimeout = ""
    var startupTimeout = ""
    var maxResultCharacters = ""
    var oauthClientID = ""
    var oauthClientSecret = ""
    var oauthCallbackPort = ""

    init() {}

    init(config: MCPServerConfig, secrets: MCPServerSecrets) {
        name = config.name
        kind = config.kind
        command = config.command
        arguments = secrets.args.joined(separator: "\n")
        workingDirectory = config.workingDirectory ?? ""
        url = secrets.url
        environment = config.envNames.map { Pair(name: $0, value: secrets.env[$0] ?? "") }
        headers = config.headerNames.map { Pair(name: $0, value: secrets.headers[$0] ?? "") }
        // A server just made with +: its first valid Save turns it on.
        isEnabled = config.isEnabled || config.identityFingerprint.isEmpty
        useInNewChats = config.useInNewChats
        callTimeout = config.callTimeout.map { String(Int($0)) } ?? ""
        startupTimeout = config.startupTimeout.map { String(Int($0)) } ?? ""
        maxResultCharacters = config.maxResultCharacters.map(String.init) ?? ""
        oauthClientID = secrets.oauthClientID
        oauthClientSecret = secrets.oauthClientSecret
        oauthCallbackPort = secrets.oauthCallbackPort.map(String.init) ?? ""
    }

    private static func values(_ pairs: [Pair]) -> [String: String] {
        var out: [String: String] = [:]
        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { out[name] = pair.value }
        }
        return out
    }

    private static func positive(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func seconds(_ text: String) -> Double? {
        positive(text).map { min(Double($0), MCPServerConfig.maxTimeout) }
    }

    /// Blank means the default. Anything else that is no whole number would be ignored silently.
    private static func isBlankOrPositive(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || positive(text) != nil
    }

    /// What Save writes. Only the fields of the form: the tool list and approvals are live.
    func applied(to config: MCPServerConfig) -> (config: MCPServerConfig, secrets: MCPServerSecrets) {
        var config = config
        var secrets = MCPServerSecrets()
        config.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.kind = kind
        config.isEnabled = isEnabled
        config.useInNewChats = useInNewChats
        config.callTimeout = Self.seconds(callTimeout)
        config.startupTimeout = Self.seconds(startupTimeout)
        config.maxResultCharacters = Self.positive(maxResultCharacters)
        if kind == MCPServerConfig.kindHTTP {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            secrets.url = trimmed
            secrets.headers = Self.values(headers)
            secrets.oauthClientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            secrets.oauthClientSecret = oauthClientSecret
            secrets.oauthCallbackPort = Self.positive(oauthCallbackPort)
            config.urlHost = URLComponents(string: trimmed)?.host ?? ""
            config.headerNames = secrets.headers.keys.sorted()
            config.command = ""
            config.workingDirectory = nil
            config.envNames = []
        } else {
            secrets.args = arguments.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            secrets.env = Self.values(environment)
            config.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            config.workingDirectory = folder.isEmpty ? nil : folder
            config.envNames = secrets.env.keys.sorted()
            config.urlHost = ""
            config.headerNames = []
        }
        return (config, secrets)
    }

    /// Why this cannot be saved, or nil.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name." }
        if kind == MCPServerConfig.kindHTTP {
            let comps = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let scheme = comps?.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = comps?.host, !host.isEmpty else {
                return "Enter a full URL such as https://example.com/mcp."
            }
            let port = oauthCallbackPort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !port.isEmpty, !(Int(port).map { (1024...65535).contains($0) } ?? false) {
                return "The callback port is a number from 1024 to 65535. Leave it blank to use a free one."
            }
        } else if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the program to run."
        }
        if ![callTimeout, startupTimeout, maxResultCharacters].allSatisfy(Self.isBlankOrPositive) {
            return "Timeouts and the result limit are whole numbers. Leave them blank for the default."
        }
        return nil
    }

    /// The whole command line typed into Command: the next run could only fail. (A full path may
    /// hold a space, so this does not block saving.)
    var commandWarning: String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == MCPServerConfig.kindStdio, text.contains(" "), !text.hasPrefix("/"), !text.hasPrefix("~") else { return nil }
        return MCPError.commandNotFound(name: text, searched: []).summary
    }

    /// Loopback, LAN and Tailscale addresses stay quiet, as for a provider's base URL.
    static func urlWarning(_ url: String) -> String? {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "http", let host = comps.host, !host.isEmpty,
              !ProviderEditor.isPrivateRoute(host) else { return nil }
        return "Plain http over the internet: your tokens, tool arguments and results travel unencrypted, readable by anyone on the way. Use https if the server offers it (https://…)."
    }
}

/// A tool Parley remembers a choice for, which no running server lists now: after a relaunch or
/// Stop the list is empty, and revoking "Always Allow" must not need the program it distrusts.
struct MCPRememberedTool: Equatable, Identifiable {
    let name: String
    let isAlwaysAllowed: Bool
    let isOff: Bool

    var id: String { name }

    static func list(server: MCPServerConfig, listed: [MCPTool]) -> [MCPRememberedTool] {
        let names = Set(server.alwaysAllowedTools.keys).union(server.disabledTools)
            .subtracting(listed.map(\.name))
        return names.sorted().map {
            MCPRememberedTool(name: $0, isAlwaysAllowed: server.alwaysAllowedTools[$0] != nil,
                              isOff: server.disabledTools.contains($0))
        }
    }
}

struct MCPServerEditor: View {
    @Environment(AppState.self) private var appState
    let serverID: UUID

    @ViewState private var draft = MCPServerDraft()
    @ViewState private var saved = MCPServerDraft()
    /// False until the secrets were read: saving now would overwrite them with nothing.
    @ViewState private var loaded = false
    @ViewState private var loadError: String?
    @ViewState private var saveError: String?
    @ViewState private var showLog = false

    private var server: MCPServerConfig? { appState.mcpServer(serverID) }
    private var snapshot: MCPServerSnapshot? { appState.mcpSnapshots[serverID] }
    private var isHTTP: Bool { draft.kind == MCPServerConfig.kindHTTP }
    private var isDirty: Bool { loaded && draft != saved }

    var body: some View {
        SettingsPage(labelWidth: 170) {
            statusSection
            connectionSection
            secretsSection
            if isHTTP, loaded {
                // A real Form inside the card, because the section relies on one for its
                // field labels. Columns style does not scroll and takes its content's height.
                SettingsSection(seed: 54) {
                    Form {
                        MCPSignInSection(serverID: serverID, draft: $draft, needsAttention: snapshot?.signInNeed ?? .none) {
                            draft.problem == nil && (!isDirty || save())
                        }
                    }
                    .formStyle(.columns)
                    .scrollContentBackground(.hidden)
                    .labeledContentStyle(.automatic)
                }
            }
            useSection
            toolsSection
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .onAppear(perform: load)
        // Closing Settings or switching servers must not silently drop typed values.
        // (Not for a server that was just deleted: its secrets must stay removed.)
        .onDisappear {
            guard server != nil, isDirty, draft.problem == nil else { return }
            _ = save()
        }
        .sheet(isPresented: $showLog) {
            MCPLogSheet(serverID: serverID, serverName: draft.name)
                .hideoutSheet()
        }
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            if let message = saveError ?? (isDirty ? draft.problem : nil) ?? loadError {
                SettingsNotice(.danger, message).lineLimit(2)
            }
            Spacer()
            Button("Revert") {
                draft = saved
                saveError = nil
            }
            .buttonStyle(TagButtonStyle())
            .disabled(!isDirty)
            Button("Save") { _ = save() }
                .buttonStyle(TagButtonStyle(kind: .primary))
                .disabled(!isDirty || draft.problem != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(RoomBackground(glow: false))
        .overlay(alignment: .top) { SettingsStitchLine() }
    }

    private var connectionSection: some View {
        SettingsSection("Connection", seed: 52) {
            SettingsField("Name") {
                TextField("Name", text: $draft.name)
            }
            LabeledContent("Type") {
                Picker("Type", selection: $draft.kind) {
                    Text("Local command").tag(MCPServerConfig.kindStdio)
                    Text("Remote URL").tag(MCPServerConfig.kindHTTP)
                }
                .labelsHidden()
                .fixedSize()
            }
            if isHTTP {
                SettingsField("URL") {
                    TextField("URL", text: $draft.url, prompt: Text("https://example.com/mcp").foregroundStyle(Hideout.inkSoft))
                        .textContentType(.URL)
                }
                if let warning = MCPServerDraft.urlWarning(draft.url) {
                    SettingsNotice(.caution, warning, systemImage: "exclamationmark.triangle.fill", font: .callout)
                }
            } else {
                SettingsField("Command") {
                    TextField("Command", text: $draft.command, prompt: Text("npx, uvx, or a full path").foregroundStyle(Hideout.inkSoft))
                        .font(.system(size: 12, design: .monospaced))
                        .fontDesign(.monospaced)
                }
                if let warning = draft.commandWarning {
                    SettingsNotice(.caution, warning, systemImage: "exclamationmark.triangle.fill", font: .callout)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
                    TextEditor(text: $draft.arguments)
                        .font(.system(size: 12, design: .monospaced))
                        .fontDesign(.monospaced)
                        .multilineTextAlignment(.leading)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .settingsWell()
                        .accessibilityLabel("Arguments, one per line")
                }
                SettingsField("Working folder") {
                    TextField("Working folder", text: $draft.workingDirectory, prompt: Text("your home folder").foregroundStyle(Hideout.inkSoft))
                }
                Text("Runs on your Mac with your permissions. One argument per line.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                ForEach(dangers, id: \.self) { line in
                    SettingsNotice(.danger, ToolDisplay.line(line), systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private var secretsSection: some View {
        SettingsSection(isHTTP ? "Headers" : "Environment", seed: 53) {
            if isHTTP {
                MCPPairRows(pairs: $draft.headers, namePrompt: "Authorization", addLabel: "Add Header")
            } else {
                MCPPairRows(pairs: $draft.environment, namePrompt: "API_KEY", addLabel: "Add Variable")
            }
        } footer: {
            Text("Arguments, the URL, environment values and headers are stored in your login Keychain (not synced).")
                .font(.caption)
                .foregroundStyle(Hideout.inkSoft)
        }
    }

    private var useSection: some View {
        SettingsSection("Use", seed: 55) {
            SettingsSwitchRow(isOn: $draft.isEnabled) { Text("Enabled") }
            SettingsSwitchRow(isOn: $draft.useInNewChats) { Text("Use in new chats") }
            SettingsField("Tool timeout (seconds)") {
                TextField("Tool timeout (seconds)", text: $draft.callTimeout, prompt: Text(verbatim: String(Int(MCPServerConfig.defaultCallTimeout))).foregroundStyle(Hideout.inkSoft))
            }
            SettingsField("Start timeout (seconds)") {
                TextField("Start timeout (seconds)", text: $draft.startupTimeout, prompt: Text(isHTTP ? "20" : "120").foregroundStyle(Hideout.inkSoft))
            }
            SettingsField("Result limit (characters)") {
                TextField("Result limit (characters)", text: $draft.maxResultCharacters, prompt: Text(verbatim: String(MCPServerConfig.defaultMaxResultCharacters)).foregroundStyle(Hideout.inkSoft))
            }
        }
    }

    /// The same lines the import review showed, which would otherwise never be seen again.
    private var dangers: [String] {
        guard let server else { return [] }
        let (config, secrets) = draft.applied(to: server)
        return MCPConfigImport.dangers(config: config, secrets: secrets)
    }

    /// Why Connect is off.
    private var connectBlocker: String? {
        guard loaded else { return nil }
        if let problem = draft.problem { return problem }
        return draft.isEnabled ? nil : "Turn on Enabled to connect."
    }

    /// A failed server is an error; one that will restart on next use is a warning.
    private var reasonKind: SettingsNotice.Kind {
        if case .failed = snapshot?.state ?? .stopped { return .danger }
        return .caution
    }

    private var statusSection: some View {
        SettingsSection("Status", seed: 51) {
            LabeledContent("State") {
                HStack(spacing: 6) {
                    PaperStatusDot(state: snapshot?.state ?? .stopped)
                    Text(verbatim: MCPStatusDot.label(snapshot?.state ?? .stopped))
                }
            }
            if let reason = MCPStatusDot.reason(snapshot?.state ?? .stopped) {
                SettingsNotice(reasonKind, reason)
                    .textSelection(.enabled)
            }
            if let version = snapshot?.protocolVersion {
                LabeledContent("Protocol") { Text(verbatim: version) }
            }
            if let info = snapshot?.serverInfo {
                LabeledContent("Server (its own claim)") {
                    Text(verbatim: ToolDisplay.line(info))
                        .lineLimit(2)
                }
            }
            HStack {
                Button(snapshot?.isRunning == true ? "Restart" : "Connect", action: connect)
                    .disabled(!loaded || connectBlocker != nil)
                Button("Stop") { appState.stopServer(serverID) }
                    .disabled(snapshot?.isRunning != true)
                Spacer()
                Button("View Log…") { showLog = true }
            }
            if let connectBlocker {
                Text(verbatim: connectBlocker)
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            }
        } footer: {
            Text("A chat uses this server once you turn it on there, with the wrench button (⇧⌘T).")
                .font(.caption)
                .foregroundStyle(Hideout.inkSoft)
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        if let server {
            let tools = snapshot?.tools ?? []
            let hidden = snapshot?.hiddenTools ?? []
            let remembered = MCPRememberedTool.list(server: server, listed: tools)
            if !tools.isEmpty || !hidden.isEmpty || !remembered.isEmpty {
                SettingsSection("Tools", seed: 56) {
                    ForEach(tools, id: \.name) { tool in
                        MCPToolRow(serverID: serverID, tool: tool, server: server)
                    }
                    ForEach(hidden, id: \.name) { hidden in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: ToolDisplay.line(hidden.name))
                                .font(.system(size: 12, design: .monospaced))
                                .fontDesign(.monospaced)
                                .foregroundStyle(Hideout.inkSoft)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(verbatim: "Not available: \(hidden.reason)")
                                .font(.caption)
                                .foregroundStyle(Hideout.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(remembered) { tool in
                        MCPRememberedToolRow(serverID: serverID, tool: tool)
                    }
                    if !remembered.isEmpty {
                        Text(snapshot?.isRunning == true
                             ? "The server does not list these now."
                             : "Press Connect to see the server's whole list.")
                            .font(.caption)
                            .foregroundStyle(Hideout.inkSoft)
                    }
                    if !server.alwaysAllowedTools.isEmpty {
                        Button("Reset All Approvals") { appState.resetApprovals(serverID: serverID) }
                    }
                }
            }
        }
    }

    /// The Keychain is read only when the editor opens for a server.
    private func load() {
        guard let server else { return }
        do {
            let secrets = try appState.mcpSecrets.secrets(for: serverID)
            draft = MCPServerDraft(config: server, secrets: secrets)
            saved = draft
            loaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard loaded, let server else { return false }
        let (config, secrets) = draft.applied(to: server)
        do {
            try appState.saveServer(config, secrets: secrets)
            saved = draft
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func connect() {
        if isDirty, !save() { return }
        appState.connectServer(serverID)
    }
}

/// Name and hidden value rows, for environment variables and headers.
private struct MCPPairRows: View {
    @Binding var pairs: [MCPServerDraft.Pair]
    let namePrompt: String
    let addLabel: String

    var body: some View {
        ForEach($pairs) { $pair in
            HStack(spacing: 6) {
                TextField("Name", text: $pair.name, prompt: Text(verbatim: namePrompt).foregroundStyle(Hideout.inkSoft))
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
                    .fontDesign(.monospaced)
                    .settingsWell()
                SecureField("Value", text: $pair.value, prompt: Text("value").foregroundStyle(Hideout.inkSoft))
                    .labelsHidden()
                    .settingsWell()
                Button {
                    pairs.removeAll { $0.id == pair.id }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(Hideout.inkSoft)
                .help("Remove")
                .accessibilityLabel("Remove \(pair.name)")
            }
        }
        Button(addLabel) { pairs.append(MCPServerDraft.Pair()) }
    }
}

/// A choice kept for a tool the server is not listing: it can be undone without starting anything.
private struct MCPRememberedToolRow: View {
    @Environment(AppState.self) private var appState
    let serverID: UUID
    let tool: MCPRememberedTool

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: ToolDisplay.line(tool.name))
                .font(.system(size: 12, design: .monospaced))
                .fontDesign(.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if tool.isAlwaysAllowed {
                AlwaysAllowedBadge()
                Button("Revoke") { appState.revokeAlways(serverID: serverID, tool: tool.name) }
                    .buttonStyle(SettingsLinkButtonStyle())
                    .font(.caption)
            }
            if tool.isOff {
                Text("Off").font(.caption).foregroundStyle(Hideout.inkSoft)
                Button("Turn On") { appState.setToolDisabled(serverID: serverID, tool: tool.name, disabled: false) }
                    .buttonStyle(SettingsLinkButtonStyle())
                    .font(.caption)
            }
        }
    }
}

/// One tool: on or off, its exact name, what the server says it does, its approval.
private struct MCPToolRow: View {
    @Environment(AppState.self) private var appState
    let serverID: UUID
    let tool: MCPTool
    let server: MCPServerConfig

    private var isOn: Binding<Bool> {
        Binding(
            get: { !server.disabledTools.contains(tool.name) },
            set: { appState.setToolDisabled(serverID: serverID, tool: tool.name, disabled: !$0) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: ToolDisplay.line(tool.name))
                        .font(.system(size: 12, design: .monospaced))
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if server.alwaysAllowedTools[tool.name] != nil {
                        AlwaysAllowedBadge()
                        Button("Revoke") { appState.revokeAlways(serverID: serverID, tool: tool.name) }
                            .buttonStyle(SettingsLinkButtonStyle())
                            .font(.caption)
                    }
                }
                if let description = tool.description, !description.isEmpty {
                    (Text("From the server: ") + Text(verbatim: ToolDisplay.visible(description)))
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(String(description.prefix(4000)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(tool.name, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(tool.name)
        }
    }
}

/// The server dot on paper: moss running, caution on the way or restarting, danger failed.
/// (Same spoken text as MCPStatusDot.)
private struct PaperStatusDot: View {
    let state: MCPServerState
    var onWall = false

    private var color: Color {
        switch state {
        case .ready: return Hideout.moss
        case .stopped: return onWall ? Hideout.wallInkSoft : Hideout.inkFaint
        case .starting, .restarting: return Hideout.caution
        case .failed: return Hideout.danger
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(MCPStatusDot.text(state))
    }
}

private struct AlwaysAllowedBadge: View {
    var body: some View {
        Text("Always allowed")
            .font(.caption2)
            .foregroundStyle(Hideout.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Hideout.emberWash, in: Capsule())
    }
}

/// The server's stderr, kept in memory only.
private struct MCPLogSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let serverID: UUID
    let serverName: String

    @ViewState private var lines: [String] = []

    private var text: String { lines.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Log: \(ToolDisplay.visible(serverName))").font(Hideout.title(16))
            ScrollView {
                Text(verbatim: lines.isEmpty ? "Nothing yet." : ToolDisplay.visible(text))
                    .font(.system(size: 11, design: .monospaced))
                    .fontDesign(.monospaced)
                    .foregroundStyle(lines.isEmpty ? Hideout.boardInkSoft : Hideout.boardInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Hideout.board, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Text("Kept in memory only.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                Spacer()
                Button("Copy") { Pasteboard.copy(text) }
                    .disabled(lines.isEmpty)
                Button("Clear") {
                    let mcp = appState.mcp
                    let id = serverID
                    Task { await mcp.clearLogs(serverIDs: [id]) }
                    lines = []
                }
                .disabled(lines.isEmpty)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(TagButtonStyle())
        }
        .padding(20)
        .frame(width: 620, height: 420)
        .task {
            while !Task.isCancelled {
                lines = await appState.mcp.logs(serverID: serverID)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
