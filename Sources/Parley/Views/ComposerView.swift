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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.horizontal, 2)
                }
            }

            if let err = session.composerError {
                HStack {
                    Text(err).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button { session.composerError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Attach images or text files")

                ZStack(alignment: .topLeading) {
                    if session.draftText.isEmpty {
                        Text("Message (Enter to send, Shift-Enter for a new line)")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $session.draftText,
                        height: $editorHeight,
                        focusToken: focusToken,
                        onSubmit: send,
                        onPasteFiles: { urls in AttachmentImport.importFiles(urls, into: session) },
                        onPasteImageData: { data in AttachmentImport.importImageData(data, filename: "Pasted image", into: session) }
                    )
                    .frame(height: editorHeight)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))

                if session.isStreaming {
                    Button(action: session.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .help("Send (Enter)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .onAppear { focusToken += 1 }
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
        // Dropping files on the editor attaches them instead of inserting paths.
        tv.unregisterDraggedTypes()

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

        init(_ parent: ComposerTextView) { self.parent = parent }

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
