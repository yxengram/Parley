import AppKit
import Foundation
import ParleyCore

// MCP on the app side: which servers a conversation may use, the approvals remembered per tool, and
// saving, deleting and importing servers. Nothing here starts a server: only a send in a conversation
// that lists one, or a button in Settings, does.

extension AppState {
    /// What a session needs from the app to run tools (see ConversationToolServices).
    func toolServices() -> ConversationToolServices {
        ConversationToolServices(
            host: mcp,
            enabledServers: { [weak self] settings in self?.enabledServers(for: settings) ?? [] },
            refusal: { [weak self] provider, model in self?.toolRefusal(provider: provider, model: model) },
            markRefused: { [weak self] provider, model, refusal in self?.markToolsRefused(provider: provider, model: model, refusal: refusal) },
            allowance: { [weak self] binding in self?.toolAllowance(binding) ?? .ask },
            setAlwaysAllowed: { [weak self] binding in self?.setAlwaysAllowed(binding) },
            approvalNeeded: { NSApp?.requestUserAttention(.informationalRequest) },
            maxRounds: { [weak self] in self?.settings.maxToolRounds ?? AppSettings.defaultMaxToolRounds },
            contextLimit: { [weak self] provider, model in self?.contextLimit(provider: provider, model: model) }
        )
    }

    func mcpServer(_ id: UUID) -> MCPServerConfig? {
        settings.mcpServers.first { $0.id == id }
    }

    /// The servers this conversation lists that exist and are switched on. A stale id is ignored.
    func enabledServers(for conversation: ConversationSettings) -> [MCPServerConfig] {
        let ids = conversation.mcpServerIDs ?? []
        guard !ids.isEmpty else { return [] }
        return settings.mcpServers.filter { $0.isEnabled && ids.contains($0.id) }
    }

    /// The tool definitions the next request would carry, for the idle status strip: known once a
    /// server has run this launch, 0 before.
    func toolDefinitionTokens(for conversation: ConversationSettings) -> Int {
        let listed = enabledServers(for: conversation).compactMap { server -> (config: MCPServerConfig, tools: [MCPTool])? in
            guard let tools = mcpSnapshots[server.id]?.tools, !tools.isEmpty else { return nil }
            return (server, tools.filter { !server.disabledTools.contains($0.name) })
        }
        guard !listed.isEmpty else { return 0 }
        return MCPToolCatalog(bindings: MCPToolNamer.assign(listed)).definitionTokens
    }

    // MARK: - Approvals

    func toolAllowance(_ binding: MCPToolBinding) -> ToolAllowance {
        guard let pinned = mcpServer(binding.serverID)?.alwaysAllowedTools[binding.tool.name] else { return .ask }
        return pinned == binding.tool.fingerprint ? .always : .changed
    }

    func setAlwaysAllowed(_ binding: MCPToolBinding) {
        updateServer(binding.serverID) { $0.alwaysAllowedTools[binding.tool.name] = binding.tool.fingerprint }
    }

    func revokeAlways(serverID: UUID, tool: String) {
        updateServer(serverID) { $0.alwaysAllowedTools[tool] = nil }
    }

    func resetApprovals(serverID: UUID) {
        updateServer(serverID) { $0.alwaysAllowedTools = [:] }
    }

    func setToolDisabled(serverID: UUID, tool: String, disabled: Bool) {
        updateServer(serverID) { server in
            server.disabledTools.removeAll { $0 == tool }
            if disabled { server.disabledTools.append(tool) }
        }
    }

    private func updateServer(_ id: UUID, _ change: (inout MCPServerConfig) -> Void) {
        guard let index = settings.mcpServers.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.mcpServers[index])
    }

    // MARK: - Saving

    /// Stores a server: the Keychain item first, so a failed write stores nothing and a value can
    /// never fall back to preferences. A change of what runs clears "Always Allow" (see
    /// MCPServerConfig.identityFingerprint);
    /// any change a running connection depends on stops it, and the next use starts the new one.
    @discardableResult
    func saveServer(_ config: MCPServerConfig, secrets: MCPServerSecrets) throws -> MCPServerConfig {
        if let name = secrets.invalidHeaderName { throw MCPError.invalidHeader(name) }
        var config = config
        let previous = mcpServer(config.id)
        let previousSecrets = previous == nil ? nil : try? mcpSecrets.secrets(for: config.id)
        let prints = MCPServerConfig.fingerprints(config: config, secrets: secrets)
        config.connectionFingerprint = prints.connection
        config.identityFingerprint = prints.identity
        if let previous, previous.identityFingerprint != prints.identity {
            config.alwaysAllowedTools = [:]
        }
        try mcpSecrets.setSecrets(secrets, for: config.id)
        if let index = settings.mcpServers.firstIndex(where: { $0.id == config.id }) {
            settings.mcpServers[index] = config
        } else {
            settings.mcpServers.append(config)
        }
        // Environment and header values are not in the fingerprint, so preferences reveal nothing of them.
        let changed = previous?.connectionFingerprint != prints.connection || previousSecrets != secrets
        if previous != nil, changed || !config.isEnabled {
            stopServer(config.id)
        }
        return config
    }

    /// Removes the server, its Keychain item and what is kept in memory for it. Conversations keep
    /// the stale id, which `enabledServers` ignores.
    func deleteServer(_ id: UUID) throws {
        try mcpSecrets.deleteSecrets(for: id)
        settings.mcpServers.removeAll { $0.id == id }
        forgetMCPSnapshot(id)
        let mcp = self.mcp
        Task {
            await mcp.forget(serverID: id)
            self.forgetMCPSnapshot(id)
        }
    }

    /// Saves what the import sheet reviewed. Stops at the first failure; what was saved stays.
    func importServers(_ entries: [MCPImportEntry]) throws {
        for entry in entries where entry.error == nil {
            try saveServer(entry.config, secrets: entry.secrets)
        }
    }

    /// Connect or Restart in Settings: the one way to start a server outside a send.
    func connectServer(_ id: UUID) {
        guard let server = mcpServer(id) else { return }
        let mcp = self.mcp
        Task { _ = await mcp.connect(server) }
    }

    func stopServer(_ id: UUID) {
        let mcp = self.mcp
        Task { await mcp.stop(serverID: id) }
    }
}
