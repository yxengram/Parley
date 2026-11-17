import AppKit
import SwiftUI
import ParleyCore

/// Settings > Built-in Tools: Parley's own tools, each off until it is turned on here. A tool that
/// is on is offered in every conversation; the wrench popover opts one conversation out.
struct BuiltInToolsSettingsView: View {
    @Environment(AppState.self) private var appState

    private static let folderCloudWarning = String(localized: "This folder may be synced to a cloud service. Reading a file that is not on this Mac yet downloads it first.")

    /// `BuiltInTools.Tool.title` in the interface language. (ParleyCore's titles stay English.)
    static func title(_ tool: BuiltInTools.Tool) -> String {
        switch tool {
        case .currentTime: return String(localized: "Current Time")
        case .calculate: return String(localized: "Calculator")
        case .listFiles: return String(localized: "List Files")
        case .readFile: return String(localized: "Read File")
        case .writeFile: return String(localized: "Write File")
        case .fetchURL: return String(localized: "Fetch Web Page")
        case .browseURL: return String(localized: "Browse Web Page")
        }
    }

    /// What the tool does, then whether it asks, which depends on Settings > General > Tool calls.
    static func explanation(_ tool: BuiltInTools.Tool, approval: ToolApprovalMode = .manual) -> String {
        let what: String
        switch tool {
        case .currentTime: what = String(localized: "The date, time and time zone of this Mac.")
        case .calculate: what = String(localized: "Works out arithmetic on this Mac.")
        case .listFiles: what = String(localized: "Names and sizes in the folder above, one level at a time.")
        case .readFile: what = String(localized: "Text files in the folder above (UTF-8, UTF-16, or GBK and other Chinese encodings).")
        case .writeFile: what = String(localized: "Creates or replaces text files in the folder above, as UTF-8. A file it replaces goes to the Trash first.")
        case .fetchURL: what = String(localized: "Gets one public web page, directly from this Mac, so the site sees your IP address.")
        case .browseURL: what = String(localized: "Opens one public web page in a private browser that runs its scripts, for pages Fetch Web Page reads as empty. It loads only from the site you approve, unless the switch below is on. It ignores the Mac's proxy settings. No images, no downloads, nothing kept afterwards.")
        }
        let asks: String
        if approval == .automatic {
            asks = String(localized: "Runs without asking: tool calls are set to run automatically in Settings > General.")
        } else if tool.contactsWebsites {
            asks = String(localized: "Asks every time and shows the host.")
        } else if tool.asksEveryTime {
            asks = String(localized: "Asks every time.")
        } else {
            asks = String(localized: "Runs without asking.")
        }
        return joined(what, asks)
    }

    /// Two sentences, with a space only after an ASCII stop: Chinese ends a sentence with a
    /// full-width stop and puts no space after it.
    static func joined(_ first: String, _ second: String) -> String {
        first + (first.last.map { $0.isASCII } == false ? "" : " ") + second
    }

    private func isOn(_ tool: BuiltInTools.Tool) -> Binding<Bool> {
        Binding(
            get: { appState.settings.builtInToolSettings.effectiveTools.contains(tool) },
            set: { appState.settings.setBuiltInTool(tool, on: $0) }
        )
    }

    static let otherSitesTitle = String(localized: "Let Browse Web Page load from other sites")
    static let otherSitesExplanation = String(localized: "Off: a page may load only from the address you approved, so some pages show little. On: the page's scripts may contact other websites (CDNs, analytics and the like), which see your IP address and what the page sends them. Each is still checked to be a public address; images, video, fonts, other sites' frames, popups and downloads stay blocked. The card says which way this is.")

    private var otherSitesRow: some View {
        let settings = appState.settings
        return SettingsSwitchRow(isOn: Binding(get: { settings.builtInBrowseOtherSites },
                                               set: { settings.builtInBrowseOtherSites = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.otherSitesTitle)
                Text(verbatim: Self.otherSitesExplanation)
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ tool: BuiltInTools.Tool) -> some View {
        SettingsSwitchRow(isOn: isOn(tool)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(tool))
                Text(verbatim: Self.explanation(tool, approval: appState.settings.toolApproval))
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        let settings = appState.settings
        let folder = settings.builtInFolderPath ?? ""
        SettingsPage(labelWidth: 196) {
            SettingsSection("Basic", seed: 31) {
                row(.currentTime)
                row(.calculate)
            }

            SettingsSection("Files", seed: 32) {
                LabeledContent {
                    HStack {
                        if !folder.isEmpty {
                            Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                                .help(abbreviated(folder))
                        }
                        Spacer(minLength: 6)
                        Button("Choose…", action: chooseFolder)
                        Button("Clear", action: settings.clearBuiltInFolder)
                            .disabled(folder.isEmpty)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder")
                        Text(verbatim: folder.isEmpty ? String(localized: "None. The file tools need one.") : abbreviated(folder))
                            .font(.caption)
                            .foregroundStyle(Hideout.inkSoft)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                if isCloudSyncedLocation(folder) {
                    SettingsNotice(.caution, Self.folderCloudWarning, systemImage: "icloud")
                }
                ForEach(BuiltInTools.Tool.allCases.filter(\.needsFolder), id: \.self) { tool in
                    row(tool).disabled(folder.isEmpty)
                }
            }

            SettingsSection("Web", seed: 33) {
                row(.fetchURL)
                row(.browseURL)
                otherSitesRow
                    .disabled(!settings.builtInToolSettings.effectiveTools.contains(.browseURL))
            }

            // A note taped up at the end, not a card of controls.
            Text("A tool that is on is offered in every conversation, and its name and description go to the model's provider with each request. What an approved tool returns goes there too. In ReAct mode every call asks, unless tool calls run automatically (Settings > General). Hidden files are never listed, read or written, and the model is never told where the folder is. With every tool off, Parley reads no file, writes none and contacts nothing new.")
                .font(.caption)
                .foregroundStyle(Hideout.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .paperCard(Hideout.card, seed: 34, radius: 10)
                .overlay(alignment: .top) {
                    WashiTape(color: Hideout.marigold, width: 66, height: 18, angle: -2)
                        .offset(y: -8)
                }
                .padding(.top, 6)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.builtInFolderPath = url.path
        }
    }
}
