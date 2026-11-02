import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

struct ChatView: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    @ViewState private var isDropTargeted = false
    @ViewState private var showSettingsPopover = false

    var body: some View {
        VStack(spacing: 0) {
            if let saveError = session.saveError {
                Banner(text: "Could not save: \(saveError)", systemImage: "exclamationmark.triangle.fill") {
                    session.saveError = nil
                }
            }
            MessageListView(session: session)
            Divider()
            ComposerView(session: session)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
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
        .navigationTitle(session.conversation.title)
        .navigationSubtitle(session.isEncrypted ? "Encrypted" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ProviderPicker(session: session)
                ModelPicker(session: session)
                Button {
                    showSettingsPopover.toggle()
                } label: {
                    Label("Conversation Settings", systemImage: "slider.horizontal.3")
                }
                .help("System prompt, temperature, max tokens, reasoning effort")
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    ConversationSettingsPopover(session: session)
                }
                if session.isEncrypted {
                    Button {
                        appState.lock(session.id)
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                    .help("Lock: save and remove the decrypted conversation from memory")
                }
            }
        }
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

    var body: some View {
        let messages = session.conversation.messages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty {
                        EmptyChatHint(session: session)
                            .padding(.top, 80)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            index: index,
                            isStreamingThis: session.streamingMessageID == message.id,
                            isReasoningNow: session.streamingMessageID == message.id && session.streamIsReasoning,
                            conversationBusy: session.isStreaming,
                            showUsage: appState.settings.showTokenUsage,
                            actions: actions
                        )
                        .equatable()
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: streamingProgress) {
                if session.isStreaming {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "parley.bottom"

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
            editAndResend: { session.editAndResend(messageAt: $0) },
            regenerate: { session.regenerate(messageAt: $0, settings: appState.settings) }
        )
    }
}

private struct EmptyChatHint: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    var body: some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            if let provider {
                Text(model.isEmpty ? provider.name : "\(model) · \(provider.name)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No provider configured")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            }
            Text("Attach images or text files with the paperclip, drag and drop, or paste.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Toolbar pickers

private struct ProviderPicker: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    var body: some View {
        let providers = appState.settings.providers
        let current = appState.settings.resolvedProvider(for: session.conversation.settings)
        Picker("Provider", selection: Binding<UUID?>(
            get: { current?.id },
            set: { newID in
                guard let newID, newID != session.conversation.settings.providerID else { return }
                session.conversation.settings.providerID = newID
                if let p = appState.settings.provider(id: newID), !p.defaultModel.isEmpty {
                    session.conversation.settings.model = p.defaultModel
                }
                session.settingsChanged(debounced: false)
            }
        )) {
            if providers.isEmpty {
                Text("No providers").tag(UUID?.none)
            }
            ForEach(providers) { p in
                Text(p.name).tag(UUID?.some(p.id))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 120, maxWidth: 200)
        .help("API provider")
        .disabled(session.isStreaming)
    }
}

private struct ModelPicker: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession
    @ViewState private var isRefreshing = false

    var body: some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let models = provider.flatMap { appState.modelsByProvider[$0.id] } ?? []
        HStack(spacing: 2) {
            TextField(
                "Model",
                text: Binding(
                    get: { session.conversation.settings.model },
                    set: {
                        session.conversation.settings.model = $0
                        session.settingsChanged(debounced: true)
                    }
                ),
                prompt: Text(provider?.defaultModel.isEmpty == false ? provider!.defaultModel : "model id")
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .disabled(session.isStreaming)

            Menu {
                if models.isEmpty {
                    Text("No models loaded")
                }
                ForEach(models, id: \.self) { m in
                    Button(m) {
                        session.conversation.settings.model = m
                        session.settingsChanged(debounced: false)
                    }
                }
                Divider()
                Button(isRefreshing ? "Refreshing…" : "Refresh Model List") {
                    guard let provider else { return }
                    isRefreshing = true
                    Task {
                        await appState.refreshModels(for: provider)
                        isRefreshing = false
                    }
                }
                .disabled(provider == nil || isRefreshing)
                if let err = appState.modelFetchError {
                    Text(err)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a model from the server")
            .disabled(session.isStreaming)
        }
    }
}
