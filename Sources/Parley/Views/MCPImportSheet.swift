import AppKit
import SwiftUI
import ParleyCore

/// Pasting a config from another MCP client. Parley reads no other app's files: the text comes from
/// the user, and every entry is shown in full before anything is stored. Nothing starts either way.
struct MCPImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Gets the first imported server, to select it.
    var onImported: (UUID?) -> Void = { _ in }

    @ViewState private var text = ""
    @ViewState private var entries: [MCPImportEntry] = []
    @ViewState private var chosen: Set<UUID> = []
    @ViewState private var reviewing = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import MCP Servers").font(.headline)
            if reviewing { review } else { paste }
            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if reviewing {
                    Button("Back") {
                        reviewing = false
                        error = nil
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if reviewing {
                    Button("Import") { importChosen() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                } else {
                    Button("Review") { parse() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        #if DEBUG
        .onAppear {
            if let sample = SnapshotHarness.importSampleText {
                text = sample
                parse()
            }
        }
        #endif
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a server config from another MCP client: an object with mcpServers or servers, or the entries alone. Parley does not read other apps' files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            Button("Paste from Clipboard") {
                // Read only on this press.
                if let pasted = NSPasteboard.general.string(forType: .string) { text = pasted }
            }
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    MCPImportRow(entry: entry, isOn: Binding(
                        get: { chosen.contains(entry.id) },
                        set: { on in
                            if on { chosen.insert(entry.id) } else { chosen.remove(entry.id) }
                        }
                    ))
                }
                Text("Nothing starts when you import. Turn a server on for a chat with the wrench button (⇧⌘T).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parse() {
        do {
            entries = try MCPConfigImport.parse(text, existingNames: appState.settings.mcpServers.map(\.name))
            // A danger line is worth a deliberate tick: Return must not import it.
            chosen = Set(entries.filter { $0.error == nil && $0.danger.isEmpty }.map(\.id))
            reviewing = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importChosen() {
        let picked = entries.filter { chosen.contains($0.id) }
        do {
            try appState.importServers(picked)
            onImported(picked.first?.config.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One server under review: the exact command or URL, untruncated, and what deserves a second look.
private struct MCPImportRow: View {
    let entry: MCPImportEntry
    @Binding var isOn: Bool

    private var isStdio: Bool { entry.config.kind == MCPServerConfig.kindStdio }

    private var commandLine: String {
        // An entry refused before it got a command has nothing to show.
        guard isStdio else { return ToolDisplay.line(entry.secrets.url) }
        return entry.config.command.isEmpty ? "" : ToolDisplay.commandLine([entry.config.command] + entry.secrets.args)
    }

    /// The danger lines already show the other variables' values.
    private var hiddenNames: [String] {
        entry.config.envNames.filter { !MCPConfigImport.changesWhatRuns($0) } + entry.config.headerNames
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Import", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(entry.error != nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ToolDisplay.line(entry.config.name))
                    .font(.body.weight(.medium))
                ForEach(entry.danger, id: \.self) { line in
                    Label(ToolDisplay.line(line), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !commandLine.isEmpty {
                    Text(verbatim: commandLine)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let folder = entry.config.workingDirectory {
                    Text(verbatim: "Working folder: \(ToolDisplay.line(folder))")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = MCPServerDraft.urlWarning(entry.secrets.url) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = entry.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isStdio {
                    Text("Runs this program on your Mac with your permissions.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(entry.warnings, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hiddenNames.isEmpty {
                    Text(verbatim: "Values hidden: " + hiddenNames.map(ToolDisplay.line).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.error == nil {
                    Text(isStdio
                         ? "Arguments and environment values go to your login Keychain."
                         : "The URL and header values go to your login Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
