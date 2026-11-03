import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

struct ComposerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: ConversationSession
    @ViewState private var editorHeight: CGFloat = ComposerTextView.minHeight
    @ViewState private var focusToken = 0

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

            if let err = session.composerError {
                HStack(alignment: .firstTextBaseline) {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button { session.composerError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 6)
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach images or text files")
                .accessibilityLabel("Attach Files")

                ZStack(alignment: .topLeading) {
                    if session.draftText.isEmpty {
                        Text(placeholder)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
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
                .padding(.vertical, 2)
                .help("Enter sends, Shift-Enter adds a new line. ↑ edits your last message.")

                if session.isStreaming {
                    Button(action: session.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating (Esc or ⌘.)")
                    .accessibilityLabel("Stop Generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Enter)")
                    .accessibilityLabel("Send Message")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .modifier(ComposerBackground())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        // The context status strip sits right below.
        .padding(.bottom, 6)
        // Lines the composer up with the message text (rows have 20 pt of side padding).
        .frame(maxWidth: Layout.contentMaxWidth - 8)
        .frame(maxWidth: .infinity)
        .onAppear { focusToken += 1 }
        .onChange(of: session.pendingEditMessageID) { _, id in
            if id != nil { focusToken += 1 }
        }
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

/// Liquid Glass on macOS 26 and later, a material elsewhere.
private struct ComposerBackground: ViewModifier {
    private static var usesGlass: Bool {
        #if DEBUG
        // The snapshot harness cannot render glass; its legacy-SDK mode shows the fallback.
        if SnapshotHarness.disablesGlass { return false }
        #endif
        return true
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *), Self.usesGlass {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.secondary.opacity(0.2)))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
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
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message")
                    .font(.callout.weight(.medium))
                Text(laterCount > 0
                     ? "Sending replaces it and the \(laterCount) message\(laterCount == 1 ? "" : "s") after it. Esc cancels."
                     : "Sending replaces it. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        tv.textColor = .labelColor
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: PastingTextView?
        var lastFocusToken = -1
        /// The composer's own undo stack, separate from other fields in the window.
        let undo = UndoManager()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
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
