import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

struct ComposerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: ConversationSession
    @ViewState private var editorHeight: CGFloat = ComposerTextView.minHeight
    @ViewState private var focusToken = 0
    @ViewState private var showToolsPopover = false

    private var canSend: Bool {
        !session.isStreaming
            && (!session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.draftAttachments.isEmpty)
    }

    private var placeholder: String {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        return model.isEmpty ? "Message" : "Message \(model)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editIndex = session.pendingEditIndex {
                EditingBar(laterCount: session.conversation.messages.count - editIndex - 1) {
                    session.cancelEdit()
                    focusToken += 1
                }
            }

            if !session.draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(session.draftAttachments) { a in
                            switch a.kind {
                            case .image:
                                ImageThumbnail(attachment: a, size: 56) { remove(a) }
                            case .text:
                                TextFileChip(attachment: a) { remove(a) }
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
                }
            }

            if let warning = serverWarning {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Hideout.caution)
                        .accessibilityHidden(true)
                    Text(warning)
                        .foregroundStyle(Hideout.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .noticeCard(fill: Hideout.cautionWash, edge: Hideout.caution, radius: 10)
            }

            if let err = session.composerError {
                HStack(alignment: .firstTextBaseline) {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Hideout.danger)
                    Spacer()
                    Button { session.composerError = nil } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Hideout.danger)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .noticeCard(fill: Hideout.dangerWash, edge: Hideout.danger, radius: 10)
            }

            HStack(alignment: .bottom, spacing: 7) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(RoundIconButtonStyle(size: 32, hoverFill: Hideout.composerWash))
                .help("Attach images or text files")
                .accessibilityLabel("Attach Files")

                if appState.settings.offersTools {
                    toolsButton
                }

                ZStack(alignment: .topLeading) {
                    if session.draftText.isEmpty {
                        Text(placeholder)
                            .lineLimit(1)
                            .font(.body)
                            .fontDesign(nil)
                            .foregroundStyle(Hideout.inkSoft)
                            .padding(.leading, 5)
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $session.draftText,
                        height: $editorHeight,
                        focusToken: focusToken,
                        onSubmit: send,
                        onEscape: escape,
                        onEditLast: editLast,
                        onPasteFiles: { urls in AttachmentImport.importFiles(urls, into: session) },
                        onPasteImageData: { data in AttachmentImport.importImageData(data, filename: "Pasted image", into: session) }
                    )
                    .frame(height: editorHeight)
                }
                // Centres a single line on the round buttons.
                .padding(.vertical, 5)
                .help("Enter sends, Shift-Enter adds a new line. ↑ edits your last message.")

                if session.isStreaming {
                    // Inked in, with a square: nothing like the ember paper plane it replaces.
                    Button(action: session.stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(ComposerActionButtonStyle(fill: Hideout.ink, icon: Hideout.paper))
                    .help("Stop generating (Esc or ⌘.)")
                    .accessibilityLabel("Stop Generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(x: -0.5, y: 0.5)
                    }
                    .buttonStyle(ComposerActionButtonStyle(fill: canSend ? Hideout.ember : Hideout.paperDeep,
                                                           icon: canSend ? Hideout.onEmber : Hideout.inkFaint,
                                                           raised: canSend))
                    .disabled(!canSend)
                    .help("Send (Enter)")
                    .accessibilityLabel("Send Message")
                }
            }
            // Clear of the stitching, which runs 5 pt inside the card's edge.
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .stitchedCard(Hideout.composerCard, seed: 4, radius: 20)
        }
        .padding(.horizontal, 16)
        // Room for the backdrop's fade, so it stays inside the safe-area inset.
        .padding(.top, ComposerStripBackdrop.fadeHeight + 6)
        // The context status strip sits right below.
        .padding(.bottom, 6)
        // Lines the composer up with the message text (rows have 20 pt of side padding).
        .frame(maxWidth: Layout.contentMaxWidth - 8)
        .frame(maxWidth: .infinity)
        // Runs on under the status strip, which draws on top of it; the window clips the rest.
        .background { ComposerStripBackdrop().padding(.bottom, -44) }
        .onAppear { focusToken += 1 }
        .onChange(of: session.pendingEditMessageID) { _, id in
            if id != nil { focusToken += 1 }
        }
        .onChange(of: appState.toolsPopoverRequest) { _, id in
            guard id == session.id else { return }
            appState.toolsPopoverRequest = nil
            showToolsPopover = true
        }
    }

    /// Only with a server configured or a built-in tool on. Accent-tinted, with a count on a small
    /// ember badge, while servers are on; the built-in tools count as one.
    private var toolsButton: some View {
        let count = appState.enabledServers(for: session.conversation.settings).count
        return Button {
            showToolsPopover.toggle()
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(count > 0 ? Hideout.emberText : Hideout.inkSoft)
        }
        .buttonStyle(RoundIconButtonStyle(size: 32, hoverFill: Hideout.composerWash))
        .disabled(session.isStreaming)
        .help("Tools: what this conversation can use (⇧⌘T)")
        .accessibilityLabel("Tools")
        .accessibilityValue(count == 1 ? "1 source on" : "\(count) sources on")
        .popover(isPresented: $showToolsPopover, arrowEdge: .top) {
            ConversationToolsPopover(session: session)
                .hideoutSheet()
        }
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Hideout.onEmber)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Hideout.ember, in: Capsule())
                    .offset(x: 5, y: -5)
                    .allowsHitTesting(false)
                    // The button's accessibility value already says it.
                    .accessibilityHidden(true)
            }
        }
    }

    /// Before sending: what the server is known to refuse. A warning, not a block: the server's
    /// answer may have changed (Pictures turned on in Strata) since it was learned.
    private var serverWarning: String? {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        guard let provider, !model.isEmpty, let info = appState.contextInfo(provider: provider, model: model) else { return nil }
        // What the next request sends again (a staged edit replaces its message and the later ones).
        let history = session.pendingEditIndex.map { Array(session.conversation.messages.prefix($0)) } ?? session.conversation.messages
        return Self.serverWarning(info: info, providerName: provider.name, model: model, history: history,
                                  draft: session.draftAttachments, draftText: session.draftText,
                                  // A conversation with only built-in tools stays a plain chat here too.
                                  hasToolServers: appState.enabledServers(for: session.conversation.settings)
                                      .contains { $0.kind != MCPServerConfig.kindBuiltIn },
                                  usesReAct: session.conversation.settings.usesReAct)
    }

    static func serverWarning(info: ModelContextInfo, providerName: String, model: String, history: [Message],
                              draft: [Attachment], draftText: String, hasToolServers: Bool = false,
                              usesReAct: Bool = false) -> String? {
        let isImage = { (a: Attachment) in a.kind == .image && a.data != nil }
        let draftHasImages = draft.contains(where: isImage)
        let historyHasImages = history.contains { $0.role == .user && $0.attachments.contains(where: isImage) }
        if info.acceptsImages == false, historyHasImages {
            return info.serverKind == .strata
                ? "\(model) on \(providerName) does not read images (Pictures is off for it in Strata), and every message sends this conversation's earlier images again. Turn Pictures on in Strata, or fork from a message before the first image."
                : "\(providerName) says \(model) does not read images, and every message sends this conversation's earlier images again. Fork from a message before the first image, or choose a model that does."
        }
        if info.acceptsImages == false, draftHasImages {
            return info.serverKind == .strata
                ? "\(model) on \(providerName) does not read images (Pictures is off for it in Strata). Remove the image, or turn Pictures on in Strata first."
                : "\(providerName) says \(model) does not read images. Remove the image, or choose a model that does."
        }
        if let limit = info.maxRequestBytes, draftHasImages || history.contains(where: { !$0.attachments.isEmpty || $0.toolRounds != nil }) {
            let bytes = estimatedRequestBytes(history, draft: draft, text: draftText)
            if bytes > limit {
                let mb = { (n: Int) in String(format: "%.1f MB", Double(n) / 1_048_576) }
                if !draftHasImages, !historyHasImages {
                    return "With its tool results this conversation is about \(mb(bytes)) per request, more than the \(mb(limit)) \(providerName) accepts: every message sends them again. Fork from an earlier message, or roll back."
                }
                return "With its images this conversation is about \(mb(bytes)) per request, more than the \(mb(limit)) \(providerName) accepts: every message sends the images again. Remove some, or fork from a message before the first image."
            }
        }
        if hasToolServers, info.ignoresTools, !usesReAct {
            return "Tools will not be offered: Strata runs this model in its runtime mode, which ignores them. Use a native model in Strata."
        }
        return nil
    }

    /// Roughly what ChatClient will send: attachments base64-encoded (4/3), text as UTF-8.
    static func estimatedRequestBytes(_ messages: [Message], draft: [Attachment], text: String) -> Int {
        func size(_ attachments: [Attachment]) -> Int {
            attachments.reduce(0) { $0 + ($1.data?.count ?? 0) * 4 / 3 + ($1.text?.utf8.count ?? 0) }
        }
        func toolData(_ message: Message) -> Int {
            (message.toolRounds ?? []).reduce(0) { total, round in
                round.calls.reduce(total + round.content.utf8.count) {
                    $0 + $1.name.utf8.count + $1.replayArguments.utf8.count + $1.replayResult.utf8.count + 64
                }
            }
        }
        let history = messages.reduce(0) { $0 + $1.content.utf8.count + 32 + ($1.role == .user ? size($1.attachments) : 0) + toolData($1) }
        return history + text.utf8.count + size(draft)
    }

    private func remove(_ a: Attachment) {
        session.draftAttachments.removeAll { $0.id == a.id }
    }

    private func send() {
        guard canSend else { return }
        let text = session.draftText
        let attachments = session.draftAttachments
        session.draftText = ""
        session.draftAttachments = []
        session.composerError = nil
        session.send(text: text, attachments: attachments, settings: appState.settings)
    }

    /// Esc: stop a streaming reply, or cancel an edit. Returns false when there is nothing to do.
    private func escape() -> Bool {
        if session.isStreaming {
            session.stop()
            return true
        }
        if session.pendingEditMessageID != nil {
            session.cancelEdit()
            return true
        }
        return false
    }

    /// ↑ in an empty composer: edit the last user message.
    private func editLast() -> Bool {
        guard !session.isStreaming, session.draftText.isEmpty, session.draftAttachments.isEmpty,
              session.pendingEditMessageID == nil,
              let index = session.lastUserMessageIndex else { return false }
        session.beginEdit(messageAt: index)
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Attach images or text files"
        guard panel.runModal() == .OK else { return }
        AttachmentImport.importFiles(panel.urls, into: session)
    }
}

/// The strip behind the composer and the status line: the room's own paper, so the transcript
/// fades out behind it instead of showing around the card. After lights-out it keeps the lantern's
/// glow, which is centred on this edge of the room; the afternoon sun is at the far corner.
private struct ComposerStripBackdrop: View {
    static let fadeHeight: CGFloat = 18

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoomBackground(glow: scheme == .dark)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Hideout.paper.opacity(0), Hideout.paper],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                    Hideout.paper
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The composer's big round button: send, or stop.
private struct ComposerActionButtonStyle: ButtonStyle {
    var fill: Color
    var icon: Color
    var raised = true

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, fill: fill, icon: icon, raised: raised)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let fill: Color
        let icon: Color
        let raised: Bool
        @ViewState private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(icon)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(fill)
                        .brightness(pressed ? -0.05 : hovering && raised ? 0.03 : 0)
                        .shadow(color: Hideout.board.opacity(raised && !pressed ? 0.2 : 0), radius: 1.5, y: 1)
                }
                .scaleEffect(pressed ? 0.95 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

/// Shown above the composer while a sent message is being edited.
private struct EditingBar: View {
    let laterCount: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .foregroundStyle(Hideout.emberText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message")
                    .font(.callout.weight(.medium))
                Text(laterCount > 0
                     ? "Sending replaces it and the \(laterCount) message\(laterCount == 1 ? "" : "s") after it. Esc cancels."
                     : "Sending replaces it. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(TagButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The user's own note, taken down from the conversation for another go.
        .paperCard(Hideout.peach, seed: 9, radius: 12)
        .overlay(alignment: .topTrailing) {
            WashiTape(color: Hideout.marigold, width: 46, height: 13, angle: 3)
                .offset(x: -14, y: -6)
        }
    }
}

// MARK: - Attachment import

@MainActor
enum AttachmentImport {
    static func importFiles(_ urls: [URL], into session: ConversationSession) {
        guard !urls.isEmpty else { return }
        Task {
            let results: [Result<Attachment, Error>] = await Task.detached(priority: .userInitiated) {
                urls.map { url in Result { try AttachmentLoader.load(url: url) } }
            }.value
            var errors: [String] = []
            for r in results {
                switch r {
                case .success(let a): session.draftAttachments.append(a)
                case .failure(let e): errors.append(e.localizedDescription)
                }
            }
            session.composerError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }

    static func importImageData(_ data: Data, filename: String, into session: ConversationSession) {
        Task {
            do {
                let a = try await Task.detached(priority: .userInitiated) {
                    try AttachmentLoader.image(data: data, filename: filename)
                }.value
                session.draftAttachments.append(a)
            } catch {
                session.composerError = error.localizedDescription
            }
        }
    }

    /// Accepts dropped file URLs and raw image data (no remote URLs are fetched).
    static func handleDrop(providers: [NSItemProvider], session: ConversationSession) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in importFiles([url], into: session) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in importImageData(data, filename: "Dropped image", into: session) }
                }
            }
        }
        return handled
    }
}

// MARK: - NSTextView wrapper

/// Multi-line editor: Enter sends, Shift-Enter inserts a newline. IME-safe
/// (Enter while composing marked text is left to the input method). Paste of
/// images or files becomes attachments.
struct ComposerTextView: NSViewRepresentable {
    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 200

    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    var onSubmit: () -> Void
    /// Esc. Returns true when handled.
    var onEscape: () -> Bool = { false }
    /// ↑ with the caret on the first line. Returns true when handled.
    var onEditLast: () -> Bool = { false }
    var onPasteFiles: ([URL]) -> Void
    var onPasteImageData: (Data) -> Void
    /// Read while the parent builds this view, so a change of skin reaches `updateNSView`.
    var skin = Hideout.skin

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = PastingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont.preferredFont(forTextStyle: .body)
        applyColors(to: tv)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.onPasteFiles = { onPasteFiles($0) }
        tv.onPasteImageData = { onPasteImageData($0) }
        // Dropped text is inserted as usual; dropped files become attachments (PastingTextView)
        // instead of inserting their paths.
        tv.unregisterDraggedTypes()
        tv.registerForDraggedTypes([.fileURL, .string])

        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        tv.onPasteFiles = { onPasteFiles($0) }
        tv.onPasteImageData = { onPasteImageData($0) }
        if context.coordinator.appliedSkin != skin {
            context.coordinator.appliedSkin = skin
            context.coordinator.recolorAfterEdits = true
            applyColors(to: tv)
        }
        if tv.string != text {
            // A programmatic change (sent, edit started or cancelled): old typing steps no longer
            // apply to this text, so they must not be undoable.
            tv.breakUndoCoalescing()
            context.coordinator.undo.removeAllActions()
            tv.string = text
            context.coordinator.recalcHeight()
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    private func applyColors(to tv: NSTextView) {
        tv.textColor = NSColor(Hideout.ink)
        tv.insertionPointColor = NSColor(Hideout.emberText)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Hideout.composerWash),
                                     .foregroundColor: NSColor(Hideout.ink)]
        // Text that replaces the whole string, and pasted text, takes its colour from here.
        tv.typingAttributes[.foregroundColor] = NSColor(Hideout.ink)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        lazy var appliedSkin = parent.skin
        /// After a change of skin, undo can bring back text in the old skin's ink.
        var recolorAfterEdits = false
        weak var textView: PastingTextView?
        var lastFocusToken = -1
        /// The composer's own undo stack, separate from other fields in the window.
        let undo = UndoManager()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if recolorAfterEdits && !tv.hasMarkedText() { tv.textColor = NSColor(Hideout.ink) }
            if parent.text != tv.string { parent.text = tv.string }
            recalcHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if textView.hasMarkedText() { return false }
                return parent.onEscape()
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if textView.hasMarkedText() || !textView.string.isEmpty { return false }
                return parent.onEditLast()
            }
            return false
        }

        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(used, ComposerTextView.minHeight), ComposerTextView.maxHeight)
            if abs(parent.height - h) > 0.5 {
                parent.height = h
            }
        }
    }
}

final class PastingTextView: NSTextView {
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImageData: ((Data) -> Void)?

    /// Copy/cut write plain text with `.currentHostOnly`, so drafts never reach Universal Clipboard.
    override func copy(_ sender: Any?) {
        guard let text = selectedPlainText() else { NSSound.beep(); return }
        Pasteboard.copy(text)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, let text = selectedPlainText() else { NSSound.beep(); return }
        Pasteboard.copy(text)
        // delete(_:) goes through the normal editing path: undo and textDidChange keep working.
        delete(sender)
    }

    private func selectedPlainText() -> String? {
        let ns = string as NSString
        let parts = selectedRanges
            .map { $0.rangeValue }
            .filter { $0.length > 0 && NSMaxRange($0) <= ns.length }
            .map { ns.substring(with: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // File drops attach the files; text drops are inserted normally.
    private func droppedFileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onPasteFiles?(urls)
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFiles?(urls)
            return
        }
        // Plain text wins over images (e.g. text copied from a web page may carry both).
        if pb.string(forType: .string) == nil {
            if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
                onPasteImageData?(data)
                return
            }
        }
        pasteAsPlainText(sender)
    }
}
