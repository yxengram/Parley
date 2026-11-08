import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

struct ChatView: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession

    @ViewState private var isDropTargeted = false
    @ViewState private var showSettingsPopover = false
    @ViewState private var confirmRegenerateLast = false

    var body: some View {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        VStack(spacing: 0) {
            header
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
                WobblyRect(seed: 9, radius: 18, amplitude: 1)
                    .strokeBorder(Hideout.ember, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [9, 7]))
                    .overlay {
                        Label {
                            Text("Drop files to attach")
                        } icon: {
                            Image(systemName: "paperclip").foregroundStyle(Hideout.emberText)
                        }
                        .lettered(20)
                        .foregroundStyle(Hideout.ink)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .paperCard(Hideout.card, seed: 6, radius: 10)
                        .overlay(alignment: .top) {
                            WashiTape(color: Hideout.marigold, width: 76, height: 18, angle: -2.5)
                                .offset(y: -9)
                        }
                    }
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
        // ⌘R on a reply that ran tools asks first, like the row's own Regenerate.
        .onChange(of: appState.regenerateRequest) { _, id in
            guard id == session.id else { return }
            appState.regenerateRequest = nil
            confirmRegenerateLast = true
        }
        .confirmationDialog("Regenerate this reply?", isPresented: $confirmRegenerateLast) {
            Button("Regenerate", role: .destructive) {
                guard let last = session.conversation.messages.indices.last else { return }
                session.regenerate(messageAt: last, settings: appState.settings)
            }
        } message: {
            Text(MessageRow.regenerateWarning(laterCount: 0, ranTools: true))
        }
        .focusedSceneValue(\.activeSession, session)
        .navigationTitle(session.conversation.title)
    }

    private var header: some View {
        RoomHeader {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.conversation.title)
                    .font(Hideout.title(15))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Hideout.inkSoft)
                        .lineLimit(1)
                }
            }
        } trailing: {
            ModelMenu(session: session)
            Button {
                showSettingsPopover.toggle()
            } label: {
                Label("Conversation Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(RoundIconButtonStyle())
            .help("Conversation settings: system prompt, temperature, max tokens, reasoning effort (⌘I)")
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                ConversationSettingsPopover(session: session)
                    .hideoutSheet()
            }
            if session.isEncrypted {
                Button {
                    appState.lock(session.id)
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .buttonStyle(RoundIconButtonStyle())
                .help("Lock: save and remove the decrypted conversation from memory (⌘L)")
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
        HStack(spacing: 8) {
            Label {
                Text(text).foregroundStyle(Hideout.ink)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Hideout.caution)
            }
            .font(.callout)
            .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(Hideout.inkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .noticeCard(fill: Hideout.cautionWash, edge: Hideout.caution)
        .padding(.horizontal, 12)
        .padding(.top, 8)
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
                            replyPhase: streamingThis ? session.replyPhase : nil,
                            roundStartedAt: streamingThis ? session.roundStartedAt : nil,
                            pendingApproval: streamingThis ? session.pendingApproval : nil,
                            activeCallID: streamingThis ? session.activeCallID : nil,
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
                .background(OverlayScrollers())
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
                            .foregroundStyle(Hideout.ink)
                            .frame(width: 30, height: 30)
                            .background(Hideout.card, in: Circle())
                            .overlay(Circle().strokeBorder(Hideout.line))
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
            // Once per card, wherever the user was reading: the reply waits for it.
            .onChange(of: session.pendingApproval?.id) { _, id in
                guard id != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
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
        let rounds = m.toolRounds ?? []
        let calls = rounds.reduce(0) { $0 &+ $1.calls.count &+ $1.calls.filter { $0.result != nil }.count }
        return m.content.utf8.count &+ (m.reasoning?.utf8.count ?? 0) &+ (m.reactThought?.utf8.count ?? 0) &+ rounds.count &+ calls
    }

    private var actions: MessageRow.Actions {
        let session = self.session
        let appState = self.appState
        return MessageRow.Actions(
            rollback: { session.rollback(toMessageAt: $0) },
            fork: { appState.fork(session, through: $0) },
            edit: { session.beginEdit(messageAt: $0) },
            regenerate: { session.regenerate(messageAt: $0, settings: appState.settings) },
            getReply: { session.startReply(settings: appState.settings) },
            answerApproval: { session.answerApproval($1, for: $0) }
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
                HintNotice(systemImage: "exclamationmark.triangle.fill",
                           title: Text("Can't reach \(provider.name)"),
                           detail: Text("\(provider.baseURL)\n\(message)"),
                           fill: Hideout.dangerWash, edge: Hideout.danger) {
                    HStack {
                        Button("Try Again") {
                            Task { await appState.refreshModels(for: provider) }
                        }
                        .buttonStyle(TagButtonStyle())
                        SettingsLink { Text("Open Provider Settings…") }
                            .buttonStyle(TagButtonStyle())
                    }
                }
            case .loading where model.isEmpty:
                VStack(spacing: 10) {
                    FirefliesIndicator()
                    Text("Connecting to \(provider.name)…")
                        .font(Hideout.title(16))
                        .multilineTextAlignment(.center)
                    Text(provider.baseURL)
                        .font(.callout)
                        .foregroundStyle(Hideout.inkSoft)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .accessibilityElement(children: .combine)
            default:
                if model.isEmpty {
                    HintNotice(systemImage: "cpu",
                               title: Text("No model selected"),
                               detail: Text("\(provider.name) did not list any models. Choose a model at the top of the window, or set a default model in Settings."),
                               fill: Hideout.cautionWash, edge: Hideout.caution) {
                        SettingsLink { Text("Open Provider Settings…") }
                            .buttonStyle(TagButtonStyle())
                    }
                } else {
                    invitation(model: model, providerName: provider.name)
                }
            }
        } else {
            HintNotice(systemImage: "server.rack",
                       title: Text("No provider configured"),
                       detail: Text("Add an OpenAI-compatible server in Settings."),
                       fill: Hideout.cautionWash, edge: Hideout.caution) {
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(TagButtonStyle())
            }
        }
    }

    /// Ready to talk: a note left out on the floor, with the lantern on.
    private func invitation(model: String, providerName: String) -> some View {
        VStack(spacing: 6) {
            LanternMark(size: 46)
                .padding(.bottom, 2)
            Text("The lantern's on")
                .lettered(28)
            Text("Come in and say something.")
                .foregroundStyle(Hideout.inkSoft)
                .padding(.bottom, 8)
            Text(model)
                .font(Hideout.title(14))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(providerName)\nAttach images or text files with the paperclip, drag and drop, or paste.")
                .font(.callout)
                .foregroundStyle(Hideout.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(maxWidth: 430)
        .stitchedCard(Hideout.card, seed: 4, radius: 18)
        .overlay(alignment: .top) {
            WashiTape(color: Hideout.rose, width: 84, height: 20, angle: -2.5)
                .offset(y: -9)
        }
        .padding(24)
    }

    /// Something stands in the way of chatting: flat and plain, in the colour of how serious it is.
    private struct HintNotice<Actions: View>: View {
        let systemImage: String
        let title: Text
        let detail: Text
        let fill: Color
        let edge: Color
        @ViewBuilder var actions: Actions

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(edge)
                    .accessibilityHidden(true)
                title
                    .font(Hideout.title(16))
                    .foregroundStyle(Hideout.ink)
                    .multilineTextAlignment(.center)
                detail
                    .font(.callout)
                    .foregroundStyle(Hideout.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: 430)
            .noticeCard(fill: fill, edge: edge)
            .padding(24)
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

        Group {
            if session.isStreaming {
                // No model change during a reply, but a disabled Menu turns AppKit grey just when
                // the name matters most. The hidden chevron keeps the tag's width.
                HStack(spacing: 4) {
                    modelLabel(model, failure: failure, ink: Hideout.inkSoft)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .hidden()
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Model: \(model.isEmpty ? "none" : model)")
            } else {
                menu(model: model, provider: provider, models: models, state: state, failure: failure)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            ZStack {
                // The Menu takes only its own clicks; this stops the rest of the tag from
                // dragging or zooming the window through the header behind it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                ParcelTag(warning: failure != nil)
            }
        }
        .help(failure.map { "Couldn't load models from \(provider?.name ?? "the server"): \($0)" }
              ?? "Model: \(model.isEmpty ? "none" : model) · Provider: \(provider?.name ?? "none")")
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Model ID").lettered(18)
                TextField("Model ID", text: $customDraft, prompt: Text(provider?.defaultModel.isEmpty == false ? provider!.defaultModel : "e.g. qwen3-14b-instruct"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Hideout.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .paperCard(Hideout.tag, seed: 3, radius: 9)
                    .frame(width: 280)
                    .onSubmit(applyCustom)
                Text("Leave empty to use the provider's default model.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
                HStack {
                    Spacer()
                    Button("Cancel") { showCustom = false }
                        .buttonStyle(TagButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Use Model", action: applyCustom)
                        .buttonStyle(TagButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .hideoutSheet()
        }
    }

    private func modelLabel(_ model: String, failure: String?, ink: Color) -> some View {
        Label {
            Text(model.isEmpty ? "Choose Model" : model)
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
        } icon: {
            Image(systemName: failure != nil ? "exclamationmark.triangle.fill" : "cpu")
                .foregroundStyle(failure != nil ? Hideout.caution : Hideout.inkSoft)
        }
        .labelStyle(.titleAndIcon)
    }

    private func menu(model: String, provider: Provider?, models: [String], state: AppState.ModelLoadState, failure: String?) -> some View {
        let settings = appState.settings
        return Menu {
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
            modelLabel(model, failure: failure, ink: Hideout.ink)
        }
        // No bezel of its own: the tag is drawn around it, where AppKit cannot flatten it.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel("Choose Model")
    }

    /// A luggage label for the model: clipped corners, a punched hole, a bit of string. When the
    /// model list failed it turns the warning colour, drawn here so it never depends on the menu.
    private struct ParcelTag: View {
        let warning: Bool

        var body: some View {
            ZStack(alignment: .leading) {
                TagShape()
                    .fill(warning ? Hideout.cautionWash : Hideout.tag)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                TagShape()
                    .stroke(warning ? Hideout.caution : Hideout.line, lineWidth: warning ? 1.5 : 1)
                ZStack {
                    Circle()
                        .fill(Hideout.paper)
                        .overlay(Circle().strokeBorder(Hideout.line))
                        .frame(width: 7, height: 7)
                    TagString()
                        .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                        .frame(width: 14, height: 14)
                        .offset(x: -7, y: -7)
                }
                .padding(.leading, 7)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        private struct TagShape: Shape {
            func path(in rect: CGRect) -> Path {
                let cut: CGFloat = 7
                let r: CGFloat = 6
                var p = Path()
                p.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
                p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
                p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
                p.closeSubpath()
                return p
            }
        }

        /// From the hole (the bottom-right corner) up and away.
        private struct TagString: Shape {
            func path(in rect: CGRect) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + 1),
                               control: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
                return p
            }
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
