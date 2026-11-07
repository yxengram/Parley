import AppKit
import SwiftUI
import ParleyCore

/// Settings > Built-in Tools: Parley's own tools, each off until it is turned on here. A tool that
/// is on is offered in every conversation; the wrench popover opts one conversation out.
struct BuiltInToolsSettingsView: View {
    @Environment(AppState.self) private var appState

    private static let folderCloudWarning = "This folder may be synced to a cloud service. Reading a file that is not on this Mac yet downloads it first."

    static func explanation(_ tool: BuiltInTools.Tool) -> String {
        switch tool {
        case .currentTime: return "The date, time and time zone of this Mac. Runs without asking."
        case .calculate: return "Works out arithmetic on this Mac. Runs without asking."
        case .listFiles: return "Names and sizes in the folder above, one level at a time. Asks every time."
        case .readFile: return "Text files in the folder above. Asks every time."
        case .fetchURL: return "Gets one public web page, directly from this Mac, so the site sees your IP address. Asks every time and shows the host."
        }
    }

    private func isOn(_ tool: BuiltInTools.Tool) -> Binding<Bool> {
        Binding(
            get: { appState.settings.builtInToolSettings.effectiveTools.contains(tool) },
            set: { appState.settings.setBuiltInTool(tool, on: $0) }
        )
    }

    private func row(_ tool: BuiltInTools.Tool) -> some View {
        Toggle(isOn: isOn(tool)) {
            Text(verbatim: tool.title)
            Text(verbatim: Self.explanation(tool))
        }
    }

    var body: some View {
        let settings = appState.settings
        let folder = settings.builtInFolderPath ?? ""
        Form {
            Section("Basic") {
                row(.currentTime)
                row(.calculate)
            }

            Section("Files") {
                LabeledContent {
                    HStack {
                        if !folder.isEmpty {
                            Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                                .help(abbreviated(folder))
                        }
                        Button("Choose…", action: chooseFolder)
                        Button("Clear", action: settings.clearBuiltInFolder)
                            .disabled(folder.isEmpty)
                    }
                } label: {
                    Text("Folder")
                    Text(folder.isEmpty ? "None. The file tools need one." : abbreviated(folder))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if isCloudSyncedLocation(folder) {
                    Label(Self.folderCloudWarning, systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(BuiltInTools.Tool.allCases.filter(\.needsFolder), id: \.self) { tool in
                    row(tool).disabled(folder.isEmpty)
                }
            }

            Section("Web") {
                row(.fetchURL)
            }

            Section {
                Text("A tool that is on is offered in every conversation, and its name and description go to the model's provider with each request. What an approved tool returns goes there too. In ReAct mode every call asks. Hidden files are never listed or read, and the model is never told where the folder is. With every tool off, Parley reads no file and contacts nothing new.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.builtInFolderPath = url.path
        }
    }
}
