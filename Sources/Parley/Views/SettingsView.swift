import AppKit
import SwiftUI
import ParleyCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .frame(width: 700, height: 460)
                .settingsRoom()
                .tabItem { Label("Providers", systemImage: "server.rack") }
            MCPSettingsView()
                .frame(width: 760, height: 540)
                .settingsRoom()
                .tabItem { Label("MCP", systemImage: "wrench.and.screwdriver") }
            BuiltInToolsSettingsView()
                .frame(width: 560, height: 600)
                .settingsRoom()
                .tabItem { Label("Built-in Tools", systemImage: "hammer") }
            GeneralSettingsView()
                .frame(width: 560, height: 620)
                .settingsRoom()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
    }
}

// MARK: - The settings room: paper parts shared by the settings tabs

private extension View {
    /// Behind every tab: the room's paper, also under the toolbar.
    func settingsRoom() -> some View {
        background {
            RoomBackground(glow: false)
                .ignoresSafeArea()
                .background(SettingsWindowPaper(skin: Hideout.skin))
        }
    }
}

/// Paints the Settings window itself, so the system toolbar sits on paper and not on white.
private struct SettingsWindowPaper: NSViewRepresentable {
    var skin: HideoutSkin

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply()
        }

        func apply() {
            guard let window else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                window.backgroundColor = NSColor(Hideout.paper)
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.apply() }
}

/// One tab's scrolling page of cards. Rows inside it are label and value; buttons are paper tags.
struct SettingsPage<Content: View>: View {
    var labelWidth: CGFloat = 116
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The title bar is transparent, and the scroll view runs on underneath it: scrolled
        // content must stop here, with paper behind the toolbar.
        .clipped()
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .background(RoomBackground(glow: false).ignoresSafeArea(.container, edges: .top))
        }
        .buttonStyle(TagButtonStyle())
        .labeledContentStyle(SettingsRowStyle(labelWidth: labelWidth))
    }
}

/// Label in a fixed column on the left, value after it.
struct SettingsRowStyle: LabeledContentStyle {
    var labelWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .frame(width: labelWidth, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A quilted section card: a lettered title above it, rows inside, small print below.
struct SettingsSection<Content: View, Footer: View>: View {
    private let title: LocalizedStringKey?
    private let seed: Int
    private let tape: Color?
    private let content: Content
    private let footer: Footer

    init(_ title: LocalizedStringKey? = nil, seed: Int = 2, tape: Color? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.seed = seed
        self.tape = tape
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .lettered(18)
                    .foregroundStyle(Hideout.emberText)
                    .padding(.leading, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .stitchedCard(seed: seed)
                .overlay(alignment: .topTrailing) {
                    if let tape {
                        WashiTape(color: tape, width: 58, height: 17, angle: 4)
                            .offset(x: -22, y: -7)
                    }
                }
            footer
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey? = nil, seed: Int = 2, tape: Color? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, seed: seed, tape: tape, content: content, footer: { EmptyView() })
    }
}

/// A labelled text field: the visible label, and the field's own title for accessibility.
struct SettingsField<Field: View>: View {
    private let label: LocalizedStringKey
    private let field: Field

    init(_ label: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        LabeledContent(label) {
            field
                .labelsHidden()
                .settingsWell()
        }
    }
}

/// A row with a switch on the right. `label` is both what is drawn and the switch's spoken name.
struct SettingsSwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            label
                // The descriptions still have to be read while a row is off.
                .opacity(isEnabled ? 1 : 0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Toggle(isOn: $isOn) { label }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Text fields and editors, written into a recessed well of the card.
private struct PaperFieldModifier: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Hideout.paperDeep, in: shape)
            .overlay(shape.strokeBorder(focused ? Hideout.ember : Hideout.line, lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    func settingsWell() -> some View { modifier(PaperFieldModifier()) }

    /// The kraft board that holds a list of paper tags.
    func settingsKraftBoard(seed: Int) -> some View {
        self
            .padding(.vertical, 8)
            .background { WallBackground().clipShape(WobblyRect(seed: seed, radius: 14)) }
            .paperCard(Hideout.wall, seed: seed, radius: 14)
    }
}

/// A warning or an error inside a section. Flat and plain on purpose; the text is never decorated.
struct SettingsNotice: View {
    enum Kind { case caution, danger }

    let kind: Kind
    let text: String
    var systemImage: String?
    var font: Font = .caption

    init(_ kind: Kind, _ text: String, systemImage: String? = nil, font: Font = .caption) {
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
        self.font = font
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(verbatim: text)
            }
        }
        .font(font)
        .foregroundStyle(kind == .danger ? Hideout.danger : Hideout.caution)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .noticeCard(fill: kind == .danger ? Hideout.dangerWash : Hideout.cautionWash,
                    edge: kind == .danger ? Hideout.danger : Hideout.caution,
                    radius: 8)
    }
}

/// A paper tag on the kraft board: one row of the provider or server list.
struct SettingsListTag<Content: View>: View {
    let isSelected: Bool
    let id: UUID
    /// Whether the keys go to the list: without the system's highlight, the tag says so.
    var listFocused = false
    @ViewBuilder var content: Content
    @ViewState private var hovering = false

    var body: some View {
        let seed = Int(id.uuid.0) &* 251 &+ Int(id.uuid.1)
        content
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? Hideout.ink : Hideout.wallInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .paperCard(isSelected ? Hideout.tag : hovering ? Hideout.tag.opacity(0.35) : Color.clear,
                       seed: seed, radius: 8, shadow: isSelected)
            .overlay {
                if isSelected && listFocused {
                    WobblyRect(seed: seed, radius: 8)
                        .stroke(Hideout.ember, lineWidth: 1.5)
                        .allowsHitTesting(false)
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
    }
}

/// The list's rows sit straight on the board; the row draws its own selection.
extension View {
    func settingsListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsListChrome() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ListSelectionHighlightRemover())
    }
}

/// Nothing selected yet: a note in the middle of the room.
struct SettingsEmptyNote: View {
    let title: LocalizedStringKey
    let systemImage: String
    var description: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Hideout.brass)
                .accessibilityHidden(true)
            Text(title)
                .lettered(24)
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(Hideout.inkSoft)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A running quilt stitch across the room, where a divider would be.
struct SettingsStitchLine: View {
    var body: some View {
        StitchPath()
            .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [6, 5]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct StitchPath: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// Small inline actions such as Revoke: ember text on paper.
struct SettingsLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        @ViewState private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Hideout.emberText)
                .underline(hovering && isEnabled)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.55)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Providers

private struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var appState
    @ViewState private var selectedID: UUID?
    @ViewState private var confirmDelete = false
    @FocusState private var listFocused: Bool

    var body: some View {
        let settings = appState.settings
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(settings.providers) { p in
                        SettingsListTag(isSelected: selectedID == p.id, id: p.id, listFocused: listFocused) {
                            HStack {
                                Text(p.name.isEmpty ? "Untitled" : p.name)
                                    .lineLimit(1)
                                Spacer()
                                if p.id == settings.defaultProviderID {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(selectedID == p.id ? Hideout.inkSoft : Hideout.wallInkSoft)
                                }
                            }
                        }
                        .tag(p.id)
                        .settingsListRow()
                    }
                }
                .focused($listFocused)
                .settingsListChrome()
                .settingsKraftBoard(seed: 5)
                HStack(spacing: 6) {
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
                .buttonStyle(RoundIconButtonStyle(size: 26))
                .padding(.top, 8)
            }
            .padding([.leading, .top, .bottom], 20)
            .frame(width: 220)

            Group {
                if let id = selectedID, settings.providers.contains(where: { $0.id == id }) {
                    ProviderEditor(providerID: id)
                        .id(id)
                } else {
                    SettingsEmptyNote(title: "Select a provider", systemImage: "server.rack")
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

struct ProviderEditor: View {
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
        SettingsPage {
            SettingsSection(seed: 21) {
                SettingsField("Name") {
                    TextField("Name", text: $settings.providers[index].name)
                }
                SettingsField("Base URL") {
                    TextField("Base URL", text: $settings.providers[index].baseURL, prompt: Text("http://192.168.1.20:1234/v1").foregroundStyle(Hideout.inkSoft))
                        .textContentType(.URL)
                }
                if let warning = Self.urlWarning(provider.baseURL) {
                    SettingsNotice(.caution, warning, systemImage: "exclamationmark.triangle.fill", font: .callout)
                }
                SettingsField("Default model") {
                    TextField("Default model", text: $settings.providers[index].defaultModel, prompt: Text("optional").foregroundStyle(Hideout.inkSoft))
                }
            } footer: {
                Text("The base URL includes the version path; /chat/completions and /models are appended.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            }

            SettingsSection(seed: 22) {
                LabeledContent("API key") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SecureField("API key", text: $apiKeyDraft, prompt: Text("none (local servers)").foregroundStyle(Hideout.inkSoft))
                            .labelsHidden()
                            .onSubmit(saveKey)
                            .settingsWell()
                        Button(keySaved ? "Saved" : "Save Key", action: saveKey)
                            .disabled(apiKeyDraft == storedKey)
                    }
                }
                if let keyError {
                    SettingsNotice(.danger, keyError)
                }
            } footer: {
                Text("Stored in your login Keychain (not synced). Never written to preferences.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            }

            SettingsSection(seed: 23) {
                HStack {
                    Button("Test Connection", action: test)
                        .disabled(testStatus == .running)
                    switch testStatus {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .ok(let n):
                        Label("Connected, \(n) model\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Hideout.moss)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Hideout.danger)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .noticeCard(fill: Hideout.dangerWash, edge: Hideout.danger, radius: 8)
                    }
                    Spacer()
                }
                LabeledContent("New chats") {
                    if settings.defaultProviderID == providerID {
                        Label("Default provider", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Hideout.inkSoft)
                    } else {
                        Button("Make Default") { settings.defaultProviderID = providerID }
                    }
                }
            }
        }
        .onAppear(perform: loadKey)
        // Closing Settings or switching providers must not silently drop a typed key.
        // (Not for a provider that was just deleted: its key must stay removed.)
        .onDisappear {
            guard appState.settings.providers.contains(where: { $0.id == providerID }) else { return }
            if apiKeyDraft != storedKey { saveKey() }
        }
    }

    /// A Tailscale MagicDNS name (`mac.tailnet-1234.ts.net`): traffic goes through the tailnet.
    static func isTailscaleName(_ host: String) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h.hasSuffix(".ts.net")
    }

    /// Addresses whose plain http stays off the internet (for the URL warnings only, not for probes).
    static func isPrivateRoute(_ host: String) -> Bool {
        ChatClient.isLocalHost(host) || isTailscaleName(host)
    }

    static func urlWarning(_ base: String) -> String? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else {
            return "Enter a full URL such as http://localhost:1234/v1."
        }
        guard scheme == "http" || scheme == "https" else { return "Only http and https URLs are supported." }
        if comps.path.isEmpty || comps.path == "/" {
            let port = comps.port.map { ":\($0)" } ?? ""
            return "No version path. Most servers expect it to end in /v1, e.g. \(scheme)://\(host)\(port)/v1."
        }
        // Loopback, LAN and Tailscale (100.64/10 and MagicDNS *.ts.net names, WireGuard-encrypted)
        // addresses stay quiet. (.ts.net counts as private for this warning only, not for probes.)
        if scheme == "http" && !Self.isPrivateRoute(host) {
            var https = comps
            https.scheme = "https"
            https.port = nil
            return "Plain http over the internet: your API key and chats travel unencrypted, readable by anyone on the way. Use https if the server offers it (\(https.string ?? "https://…"))."
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
                testStatus = .failed(ErrorPresentation.connectionTestText(error.localizedDescription))
            }
        }
    }
}

// MARK: - General

/// One picture card for each skin. Choosing one repaints every window at once.
private struct SkinPicker: View {
    var body: some View {
        let current = Hideout.skin
        HStack(alignment: .top, spacing: 10) {
            ForEach(HideoutSkin.allCases) { skin in
                SkinCard(skin: skin, isSelected: skin == current) {
                    HideoutSkinStore.shared.skin = skin
                }
            }
        }
    }
}

private struct SkinCard: View {
    @Environment(\.colorScheme) private var scheme
    let skin: HideoutSkin
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                picture
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack(spacing: 4) {
                    Text(skin.title)
                        .font(Hideout.title(13))
                        .foregroundStyle(Hideout.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Hideout.emberText)
                    }
                }
                Text(skin.blurb)
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Hideout.emberWash : Hideout.paperDeep)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Hideout.emberText : Hideout.line, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skin.title)
        .accessibilityValue(skin.blurb)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var picture: some View {
        if let image = Hideout.art(scheme == .dark ? "fort-night" : "fort-day", skin: skin) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .accessibilityHidden(true)
        } else {
            skin.palette.wall.color
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        SettingsPage(labelWidth: 196) {
            SettingsSection("Skin", seed: 40) {
                SkinPicker()
                Text("Each skin has an afternoon and a lights-out look, which follow the system appearance.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Conversations", seed: 41) {
                LabeledContent {
                    HStack {
                        Label(settings.defaultDirectoryURL.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .help(abbreviated(settings.defaultDirectoryPath))
                        Spacer(minLength: 6)
                        Button("Choose…", action: chooseDirectory)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default folder")
                        Text(abbreviated(settings.defaultDirectoryPath))
                            .font(.caption)
                            .foregroundStyle(Hideout.inkSoft)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
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
                    SettingsNotice(.caution, cloudSyncWarning, systemImage: "icloud")
                }
                Text("Each conversation is saved as one JSON file named by a random ID. New chats can choose their own folder. Desktop and Documents may be synced by iCloud, and folders in ~/Library/CloudStorage by Dropbox, OneDrive or Google Drive; the default location in Application Support is not.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Display", seed: 42) {
                SettingsSwitchRow(isOn: $settings.showTokenUsage) {
                    Text("Show token usage under replies")
                }
            }

            SettingsSection("Privacy", seed: 43, tape: Hideout.rose) {
                Label {
                    Text("Parley only contacts the API endpoints and MCP servers you configure, sign-in providers you approve and, if you turn on Fetch Web Page, each website you approve for one call. No telemetry.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Hideout.brass)
                }
                Text("API keys live in the Keychain. Encrypted conversations are decrypted only in memory. The Copy buttons (and copying from the message box) keep text off Universal Clipboard; selected text copied with ⌘C elsewhere uses the normal clipboard, which Handoff may share with your other devices.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
