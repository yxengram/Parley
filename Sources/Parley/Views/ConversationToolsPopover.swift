import SwiftUI
import ParleyCore

/// Which MCP servers this conversation uses. Toggling starts nothing: a server starts when a message
/// is sent in a conversation that lists it.
struct ConversationToolsPopover: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: ConversationSession

    private var provider: Provider? { appState.settings.resolvedProvider(for: session.conversation.settings) }
    private var model: String { ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider) }

    private func isOn(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { session.conversation.settings.mcpServerIDs?.contains(id) ?? false },
            set: { on in
                var ids = session.conversation.settings.mcpServerIDs ?? []
                ids.removeAll { $0 == id }
                if on { ids.append(id) }
                // Nil and [] both mean none; nil keeps the file free of the key.
                session.conversation.settings.mcpServerIDs = ids.isEmpty ? nil : ids
                session.settingsChanged(debounced: false)
            }
        )
    }

    var body: some View {
        let servers = appState.settings.mcpServers.filter(\.isEnabled)
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.headline)
            if servers.isEmpty {
                Text(appState.settings.mcpServers.isEmpty
                     ? "No MCP server yet. Add one in Settings > MCP."
                     : "Every MCP server is switched off. Turn one on in Settings > MCP.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)

            let tokens = appState.toolDefinitionTokens(for: session.conversation.settings)
            if tokens > 0 {
                Text("Tool definitions: about \(TokenFormat.grouped(tokens)) tokens per request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = Self.definitionsWarning(tokens: tokens, limit: contextLimit) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let provider, !model.isEmpty, let refusal = appState.toolRefusal(provider: provider, model: model) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(provider.name) did not accept tools for \(model), so they are not offered.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(refusal.message)
                    Button("Try Again") {
                        appState.clearToolRefusal(provider: provider, model: model)
                    }
                    .controlSize(.small)
                }
            }

            Text("Tool names, descriptions, arguments and results go to the model's provider, and arguments to the MCP server. Toggling starts and stops nothing: a server starts when you send, and runs until you press Stop in Settings > MCP or quit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let snapshot = appState.mcpSnapshots[server.id]
        let state = snapshot?.state ?? .stopped
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn(server.id)) {
                HStack(spacing: 6) {
                    MCPStatusDot(state: state)
                    Text(verbatim: ToolDisplay.line(server.name))
                        .lineLimit(1)
                    if let snapshot, !snapshot.tools.isEmpty {
                        let count = snapshot.tools.filter { !server.disabledTools.contains($0.name) }.count
                        Text(count == 1 ? "1 tool" : "\(count) tools")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help(MCPStatusDot.text(state))
            if case .failed(let message) = state {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }

    private var contextLimit: ContextLimit? {
        guard let provider, !model.isEmpty else { return nil }
        return appState.contextLimit(provider: provider, model: model)
    }

    /// Past half the context, tools leave too little room for the chat, and the failure that follows
    /// would not mention them.
    static func definitionsWarning(tokens: Int, limit: ContextLimit?) -> String? {
        guard let limit, limit.tokens > 0, tokens * 2 > limit.tokens else { return nil }
        let share = min(tokens * 100 / limit.tokens, 100)
        return "That is about \(share)% of this model's context. Turn off servers or tools you do not need, or the model may refuse the request."
    }

    private var notes: [String] {
        guard let provider, !model.isEmpty, let info = appState.contextInfo(provider: provider, model: model) else { return [] }
        var notes: [String] = []
        if info.ignoresTools {
            notes.append("Strata runs this model in its runtime mode, which ignores tools. Use a native model in Strata.")
        }
        if info.serverKind == .ollama {
            notes.append("Ollama keeps only basic schema keywords.")
        }
        return notes
    }
}
