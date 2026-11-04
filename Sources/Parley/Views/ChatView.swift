import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

struct ChatView: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    @ViewState private var isDropTargeted = false
    @ViewState private var showSettingsPopover = false

    var body: some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        VStack(spacing: 0) {
            if let saveError = session.saveError {
                Banner(text: "Could not save: \(saveError)", systemImage: "exclamationmark.triangle.fill") {
                    session.saveError = nil
                }
            }
            MessageListView(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        ComposerView(session: session)
                        ContextStatusBar(session: session)
                    }
                }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop files to attach", systemImage: "paperclip").font(.title3))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            AttachmentImport.handleDrop(providers: providers, session: session)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SnapshotHarness.showConversationSettingsNotification)) { _ in
            showSettingsPopover = true
        }
        #endif
        // Only the configured endpoint of this conversation's provider is contacted.
        .task(id: ModelTaskID(providerID: provider?.id, baseURL: provider?.baseURL)) {
            guard let provider else { return }
            await appState.loadModelsIfNeeded(for: provider)
            preselectModelIfNeeded(provider: provider)
        }
        // Context length of the selected model: read-only GETs to the same server, cached.
        .task(id: ContextTaskID(providerID: provider?.id, baseURL: provider?.baseURL, model: currentModel(provider))) {
            guard let provider else { return }
            await appState.refreshContextInfo(provider: provider, model: currentModel(provider))
        }
        .onChange(of: session.isStreaming) { wasStreaming, isStreaming in
            if wasStreaming && !isStreaming { appState.replyFinished(in: session) }
        }
        .onChange(of: appState.conversationSettingsRequest) { _, id in
            guard id == session.id else { return }
            appState.conversationSettingsRequest = nil
            showSettingsPopover = true
        }
        .focusedSceneValue(\.activeSession, session)
        .navigationTitle(session.conversation.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ModelMenu(session: session)
                Button {
                    showSettingsPopover.toggle()
                } label: {
                    Label("Conversation Settings", systemImage: "slider.horizontal.3")
                }
                .help("Conversation settings: system prompt, temperature, max tokens, reasoning effort (⌘I)")
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    ConversationSettingsPopover(session: session)
                }
            }
            if session.isEncrypted {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.lock(session.id)
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                    .help("Lock: save and remove the decrypted conversation from memory (⌘L)")
                }
            }
        }
    }

    private struct ModelTaskID: Hashable {
        let providerID: UUID?
        let baseURL: String?
    }

    private struct ContextTaskID: Hashable {
        let providerID: UUID?
        let baseURL: String?
        let model: String
    }

    private func currentModel(_ provider: Provider?) -> String {
        ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
    }

    /// "Encrypted", plus the folder name when the file is outside the default folder.
    private var subtitle: String {
        var parts: [String] = []
        if session.isEncrypted { parts.append("Encrypted") }
        if !appState.settings.isInDefaultDirectory(session.fileURL) {
            parts.append(session.fileURL.deletingLastPathComponent().lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    /// A chat with no model (and a provider without a default model) gets the first one the
    /// server lists, so a first message does not fail with "No model selected".
    private func preselectModelIfNeeded(provider: Provider) {
        guard ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider).isEmpty,
              !session.isStreaming,
              let first = appState.modelsByProvider[provider.id]?.first else { return }
        session.conversation.settings.model = first
        session.scheduleSave()
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Label(text, systemImage: systemImage)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}

// MARK: - Message list

private struct MessageListView: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    /// True while the bottom of the conversation is on screen. Streaming only auto-scrolls then,
    /// so the user can scroll up and read while a reply arrives.
    @ViewState private var atBottom = true

    var body: some View {
        let messages = session.conversation.messages
        if messages.isEmpty {
            EmptyChatHint(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(messages)
        }
    }

    private func list(_ messages: [Message]) -> some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        let serverKind = provider.flatMap { model.isEmpty ? nil : appState.contextInfo(provider: $0, model: model) }?.serverKind
        let editIndex = session.pendingEditIndex
        let repeatsNote = MessageRow.repeatsThinkingOffNotes(messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let streamingThis = session.streamingMessageID == message.id
                        MessageRow(
                            message: message,
                            index: index,
                            messageCount: messages.count,
                            isStreamingThis: streamingThis,
                            isReasoningNow: streamingThis && session.streamIsReasoning,
                            thinkingStartedAt: streamingThis ? session.streamReasoningStartedAt : nil,
                            conversationBusy: session.isStreaming,
                            showUsage: appState.settings.showTokenUsage,
                            editState: editIndex.map { index == $0 ? .editing : (index > $0 ? .replaced : .none) } ?? .none,
                            providerName: provider?.name,
                            providerBaseURL: provider?.baseURL,
                            serverKind: serverKind,
                            promptProgress: streamingThis ? session.liveGeneration?.promptProgress : nil,
                            maxTokens: session.conversation.settings.maxTokens,
                            repeatsThinkingOffNote: repeatsNote[index],
                            actions: actions
                        )
                        .equatable()
                        .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: Layout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .modifier(ChatScrollAnchor())
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.2)))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .help("Scroll to the latest message")
                    .accessibilityLabel("Scroll to Bottom")
                    .transition(.opacity)
                }
            }
            .onChange(of: messages.count) {
                // A new message (sent, regenerated, rolled back): show the end.
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: streamingProgress) {
                if session.isStreaming && atBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "parley.bottom"

    /// Opens at the bottom and keeps the bottom anchored as content grows, but a conversation
    /// shorter than the window starts at the top. Linked against the macOS 15+ SDK, a plain
    /// `.defaultScrollAnchor(.bottom)` also bottom-aligns short content, leaving an empty gap
    /// above the first message.
    private struct ChatScrollAnchor: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .defaultScrollAnchor(.top, for: .alignment)
            } else {
                content.defaultScrollAnchor(.bottom)
            }
        }
    }

    /// Changes as the in-flight message grows.
    private var streamingProgress: Int {
        guard let id = session.streamingMessageID,
              let m = session.conversation.messages.last(where: { $0.id == id }) else { return -1 }
        return m.content.utf8.count &+ (m.reasoning?.utf8.count ?? 0)
    }

    private var actions: MessageRow.Actions {
        let session = self.session
        let appState = self.appState
        return MessageRow.Actions(
            rollback: { session.rollback(toMessageAt: $0) },
            fork: { appState.fork(session, through: $0) },
            edit: { session.beginEdit(messageAt: $0) },
            regenerate: { session.regenerate(messageAt: $0, settings: appState.settings) },
            getReply: { session.startReply(settings: appState.settings) }
        )
    }
}

/// Shown in a chat with no messages yet: which model will answer, or what needs setting up.
private struct EmptyChatHint: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    var body: some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        if let provider {
            switch appState.modelLoadState[provider.id] ?? .idle {
            // Only when no model is set: servers without /models still chat fine with one.
            // (A failed list fetch also shows an orange warning on the toolbar model menu.)
            case .failed(let message) where model.isEmpty:
                ContentUnavailableView {
                    Label("Can't reach \(provider.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(provider.baseURL)\n\(message)")
                } actions: {
                    HStack {
                        Button("Try Again") {
                            Task { await appState.refreshModels(for: provider) }
                        }
                        SettingsLink { Text("Open Provider Settings…") }
                    }
                }
            case .loading where model.isEmpty:
                ContentUnavailableView {
                    Label {
                        Text("Connecting to \(provider.name)…")
                    } icon: {
                        ProgressView().controlSize(.large)
                    }
                } description: {
                    Text(provider.baseURL)
                }
            default:
                if model.isEmpty {
                    ContentUnavailableView {
                        Label("No model selected", systemImage: "cpu")
                    } description: {
                        Text("\(provider.name) did not list any models. Choose a model in the toolbar, or set a default model in Settings.")
                    } actions: {
                        SettingsLink { Text("Open Provider Settings…") }
                    }
                } else {
                    ContentUnavailableView {
                        Label(model, systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("\(provider.name)\nAttach images or text files with the paperclip, drag and drop, or paste.")
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No provider configured", systemImage: "server.rack")
            } description: {
                Text("Add an OpenAI-compatible server in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        }
    }
}

// MARK: - Toolbar: model and provider

/// One toolbar menu for the model (fetched list plus a custom ID) and the provider.
private struct ModelMenu: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession
    @ViewState private var showCustom = false
    @ViewState private var customDraft = ""

    var body: some View {
        let settings = appState.settings
        let provider = settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        let models = provider.flatMap { appState.modelsByProvider[$0.id] } ?? []
        let state = provider.flatMap { appState.modelLoadState[$0.id] } ?? .idle
        let failure: String? = { if case .failed(let m) = state { return m } else { return nil } }()

        Menu {
            if let provider {
                Section(provider.name) {
                    if state == .loading && models.isEmpty {
                        Text("Loading models…")
                    } else if let failure {
                        Text("Couldn't load models: \(failure)")
                    } else if models.isEmpty {
                        Text("No models listed")
                    }
                    ForEach(models, id: \.self) { m in
                        Toggle(m, isOn: Binding(
                            get: { m == model },
                            set: { _ in select(m) }
                        ))
                    }
                    if !model.isEmpty && !models.contains(model) {
                        Toggle(model, isOn: .constant(true))
                    }
                }
            }
            Divider()
            Button("Custom Model ID…") {
                customDraft = session.conversation.settings.model
                showCustom = true
            }
            Button(state == .loading ? "Refreshing…" : "Refresh Model List") {
                guard let provider else { return }
                Task { await appState.refreshModels(for: provider) }
            }
            .disabled(provider == nil || state == .loading)
            if settings.providers.count > 1 {
                Divider()
                Menu("Provider") {
                    ForEach(settings.providers) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { p.id == provider?.id },
                            set: { _ in switchProvider(to: p) }
                        ))
                    }
                }
            }
            Divider()
            SettingsLink { Text("Provider Settings…") }
        } label: {
            Label {
                Text(model.isEmpty ? "Choose Model" : model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            } icon: {
                Image(systemName: failure != nil ? "exclamationmark.triangle.fill" : "cpu")
                    .foregroundStyle(failure != nil ? Color.orange : Color.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(failure.map { "Couldn't load models from \(provider?.name ?? "the server"): \($0)" }
              ?? "Model: \(model.isEmpty ? "none" : model) · Provider: \(provider?.name ?? "none")")
        .accessibilityLabel("Choose Model")
        .disabled(session.isStreaming)
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Model ID").font(.headline)
                TextField("Model ID", text: $customDraft, prompt: Text(provider?.defaultModel.isEmpty == false ? provider!.defaultModel : "e.g. qwen3-14b-instruct"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(applyCustom)
                Text("Leave empty to use the provider's default model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showCustom = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Use Model", action: applyCustom)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func select(_ model: String) {
        session.conversation.settings.model = model
        session.settingsChanged(debounced: false)
    }

    private func applyCustom() {
        select(customDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        showCustom = false
    }

    private func switchProvider(to p: Provider) {
        guard p.id != session.conversation.settings.providerID else { return }
        session.conversation.settings.providerID = p.id
        if !p.defaultModel.isEmpty {
            session.conversation.settings.model = p.defaultModel
        } else if let first = appState.modelsByProvider[p.id]?.first {
            session.conversation.settings.model = first
        } else {
            session.conversation.settings.model = ""
        }
        session.settingsChanged(debounced: false)
    }
}
