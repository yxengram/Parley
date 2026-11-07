import SwiftUI
import ParleyCore

// Tool rounds inside a reply: the collapsed rows, what they expand to, and the approval card.
// Model text stays markdown. Everything a server or a model chose (names, arguments, results,
// descriptions) is plain text, never markdown and never Parley's own words.

/// Plain-text forms of what a tool round holds.
enum ToolDisplay {
    /// What draws nothing, or moves what is around it: controls, format characters (bidi marks, zero
    /// widths, tags), line and paragraph separators, variation selectors. A model could hide text from
    /// the card in these, and a server could reorder a path.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return properties.isDefaultIgnorableCodePoint
        }
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    }

    private static func escaping(_ text: String, where shouldEscape: (Unicode.Scalar) -> Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if shouldEscape(scalar) {
                out.append(contentsOf: escaped(scalar).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Shows hidden scalars as `\u{…}`. Line breaks and tabs stay, for text blocks.
    static func visible(_ text: String) -> String {
        escaping(text, where: isHidden)
    }

    /// For a web address. What is sent is ASCII, so everything else is escaped as well as what
    /// `isHidden` catches: right-to-left letters reorder a line around them, and lookalike letters
    /// could fake a host. So are spaces and line breaks, which a real address does not have.
    static func address(_ text: String) -> String {
        escaping(text) { !(0x21...0x7E).contains($0.value) }
    }

    /// `visible` for one line: names and command words, where a line break could fake a row.
    static func line(_ text: String) -> String {
        visible(text).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    static func containsHidden(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHidden)
    }

    /// The command as a shell would need it: a word with spaces in quotes, so it reads as one word.
    static func commandLine(_ words: [String]) -> String {
        words.map { word in
            let shown = line(word)
            return word.isEmpty || word.contains(where: \.isWhitespace) ? "'\(shown)'" : shown
        }.joined(separator: " ")
    }

    /// For text taller than `maxHeight`: scroll bars may be hidden, and sorted keys can put what
    /// matters last. `height` is measured, since how text wraps depends on its width and its breaks.
    static func overflowLine(height: CGFloat, maxHeight: CGFloat) -> String? {
        height > maxHeight ? "About \(Int((height / textBlockRowHeight).rounded(.up))) lines. Scroll to see all of them." : nil
    }

    /// ToolTextBlock's 12 pt monospaced text with its line spacing.
    private static let textBlockRowHeight: CGFloat = 17

    /// The model's raw arguments, indented when they are JSON.
    static func prettyArguments(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return "{}" }
        guard let value = JSONValue(jsonText: trimmed) else { return raw }
        if case .object(let object) = value, object.isEmpty { return "{}" }
        return value.prettyJSONText
    }

    /// "filesystem › read_file", or the name the model used when it matches no tool.
    static func title(_ call: ToolCallRecord) -> String {
        let tool = line(call.toolName ?? call.name)
        return call.serverName.map { "\(short(line($0))) › \(tool)" } ?? tool
    }

    /// A row truncates at its end: a long server name must leave room for the tool's.
    private static func short(_ name: String) -> String {
        name.count > 24 ? name.prefix(24) + "…" : name
    }

    /// "Truncated: showing 32,000 of 58,120 characters."
    static func truncationLine(_ result: ToolCallResult) -> String? {
        guard let total = result.originalCharacters else { return nil }
        let shown = result.text.range(of: #"showing the first \d+ of"#, options: [.regularExpression, .backwards])
            .flatMap { Int(result.text[$0].filter(\.isNumber)) }
        guard let shown else { return "Truncated: \(TokenFormat.grouped(total)) characters in all." }
        return "Truncated: showing \(TokenFormat.grouped(shown)) of \(TokenFormat.grouped(total)) characters."
    }

    static func omittedLine(_ result: ToolCallResult) -> String? {
        guard let omitted = result.omitted, !omitted.isEmpty else { return nil }
        return "Not shown to the model: \(omitted.joined(separator: "; "))."
    }

    /// Copy Tool Calls: each call's name, arguments and result.
    static func copyText(_ rounds: [ToolRound]) -> String {
        rounds.flatMap(\.calls).map { call in
            "\(call.serverName.map { $0 + "." } ?? "")\(call.toolName ?? call.name)\n\(prettyArguments(call.arguments))\n\(call.replayResult)"
        }.joined(separator: "\n\n")
    }
}

/// What a row says about a call.
struct ToolCallPresentation: Equatable {
    enum Glyph: Equatable {
        case progress
        case symbol(String)
    }

    var glyph: Glyph
    var text: String

    static func make(_ call: ToolCallRecord, isActive: Bool, isPending: Bool, replyInProgress: Bool) -> ToolCallPresentation {
        guard let result = call.result else {
            if isPending { return ToolCallPresentation(glyph: .symbol("hand.raised"), text: "Waiting for your approval") }
            if isActive { return ToolCallPresentation(glyph: .progress, text: "Running…") }
            if replyInProgress { return ToolCallPresentation(glyph: .symbol("clock"), text: "Waiting") }
            return ToolCallPresentation(glyph: .symbol("stop.circle"), text: "Interrupted")
        }
        switch result.callStatus {
        case .completed: return ToolCallPresentation(glyph: .symbol("checkmark"), text: "Done")
        case .toolError: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: "Tool error")
        case .failed: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: "Failed")
        case .timedOut: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: "Timed out")
        case .denied: return ToolCallPresentation(glyph: .symbol("hand.raised"), text: "Denied")
        case .cancelled: return ToolCallPresentation(glyph: .symbol("stop.circle"), text: call.startedAt == nil ? "Stopped" : "Interrupted")
        case .notCalled: return ToolCallPresentation(glyph: .symbol("xmark"), text: "Not called")
        case nil: return ToolCallPresentation(glyph: .symbol("questionmark"), text: "Finished")
        }
    }
}

/// The rounds before the reply's final text, in order: thinking, text, then the calls.
struct ToolRoundsView: View {
    let rounds: [ToolRound]
    let replyInProgress: Bool
    let activeCallID: String?
    let pendingApproval: PendingToolApproval?
    let answer: (String, ToolApprovalDecision) -> Void

    var body: some View {
        ForEach(rounds) { round in
            if let reasoning = round.reasoning, !reasoning.isEmpty {
                ThinkingDisclosure(reasoning: reasoning, duration: round.reasoningDuration, isThinking: false, isStreaming: false)
            }
            if !round.content.isEmpty {
                MarkdownView(text: round.content)
            }
            ForEach(round.calls) { call in
                ToolCallRow(call: call, presentation: ToolCallPresentation.make(
                    call, isActive: call.id == activeCallID, isPending: call.id == pendingApproval?.id, replyInProgress: replyInProgress))
                if let pendingApproval, pendingApproval.id == call.id {
                    ToolApprovalCard(approval: pendingApproval, answer: answer)
                }
            }
        }
    }
}

/// One call, collapsed by default, styled like ThinkingDisclosure.
struct ToolCallRow: View {
    let call: ToolCallRecord
    let presentation: ToolCallPresentation

    @ViewState private var expanded = false

    private var isExpanded: Bool {
        #if DEBUG
        if SnapshotHarness.expandsToolRows { return true }
        #endif
        return expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Image(systemName: "wrench.and.screwdriver")
                    Text(verbatim: ToolDisplay.title(call))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    switch presentation.glyph {
                    case .progress: ProgressView().controlSize(.mini)
                    case .symbol(let name): Image(systemName: name)
                    }
                    Text(verbatim: presentation.text)
                    if let duration = call.result?.duration {
                        Text(verbatim: TokenFormat.seconds(duration))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ToolDisplay.title(call)), \(presentation.text)")
            .accessibilityHint(isExpanded ? "Hides the arguments and result" : "Shows the arguments and result")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ToolTextBlock(title: "Arguments", text: ToolDisplay.prettyArguments(call.arguments))
                    if call.result != nil || presentation.text == "Interrupted" {
                        ToolTextBlock(title: "Result", text: call.replayResult)
                    }
                    if let result = call.result {
                        ForEach([ToolDisplay.truncationLine(result), ToolDisplay.omittedLine(result)].compactMap { $0 }, id: \.self) { line in
                            Text(verbatim: line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 3)
                }
                .padding(.leading, 2)
            }
        }
    }
}

/// Monospaced, selectable, never markdown, and scrollable when long. `text` is shown with its
/// hidden characters made visible; Copy copies it as it is.
struct ToolTextBlock: View {
    let title: String
    let text: String
    var maxHeight: CGFloat = 240

    @ViewState private var copied = false
    @ViewState private var textHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    Pasteboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy \(title)")
                .accessibilityLabel("Copy \(title)")
            }
            ScrollView {
                Text(verbatim: ToolDisplay.visible(text))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            if let overflow = ToolDisplay.overflowLine(height: textHeight, maxHeight: maxHeight) {
                Text(verbatim: overflow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Inline at the pending call. Styled like the error callout, in the accent tint. No keyboard
/// shortcut on purpose: Return belongs to the composer, and typing must never approve anything.
struct ToolApprovalCard: View {
    let approval: PendingToolApproval
    let answer: (String, ToolApprovalDecision) -> Void

    @ViewState private var showDescription = false
    /// False for a moment after a card appears: the model controls how long the last card was, so
    /// the next one's Allow could land under a pointer that is still clicking.
    @ViewState private var armed = false
    static let armDelay: TimeInterval = 0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow this tool call?", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(ToolDisplay.line(approval.serverName)) › \(ToolDisplay.line(approval.toolName))")
                    .font(.callout.monospaced())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !approval.serverDetail.isEmpty {
                    Text(verbatim: ToolDisplay.line(approval.serverDetail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if approval.definitionChanged {
                Label("This tool's description or parameters changed since you chose Always Allow.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if approval.readFromText {
                Label("Read from the model's text, which can repeat tool output, so this call can only be allowed once.", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                    Button {
                        showDescription.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showDescription ? 90 : 0))
                                .font(.caption2.weight(.semibold))
                            Text("Definition from the server")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showDescription {
                        if let description = approval.description, !description.isEmpty {
                            Text(verbatim: ToolDisplay.visible(String(description.prefix(4000))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ToolTextBlock(title: "Parameters", text: approval.parameters, maxHeight: 160)
                    }
            }
            ToolTextBlock(title: "Arguments", text: approval.arguments, maxHeight: 220)
            if ToolDisplay.containsHidden(approval.arguments) {
                Label("The arguments contain hidden characters, shown here as \\u{…}.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Deny") { answer(approval.id, .deny) }
                    .buttonStyle(.bordered)
                Button("Allow Once") { answer(approval.id, .allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!armed)
                if !approval.readFromText {
                    Button("Always Allow This Tool") { answer(approval.id, .alwaysAllow) }
                        .buttonStyle(.bordered)
                        .disabled(!armed)
                }
            }
            .controlSize(.small)
        }
        .task(id: approval.id) {
            armed = false
            try? await Task.sleep(nanoseconds: UInt64(Self.armDelay * 1_000_000_000))
            armed = true
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Allow this tool call?")
    }
}

/// A server's status as one dot (the settings list and the tools popover).
struct MCPStatusDot: View {
    let state: MCPServerState

    private var color: Color {
        switch state {
        case .ready: return .green
        case .stopped: return .gray
        case .starting, .restarting: return .orange
        case .failed: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Self.text(state))
    }

    static func text(_ state: MCPServerState) -> String {
        switch state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .restarting(let reason): return "Stopped unexpectedly, restarts on next use: \(reason)"
        case .failed(let message): return message
        }
    }

    /// The state in a few words, for a row with `reason` below it.
    static func label(_ state: MCPServerState) -> String {
        switch state {
        case .restarting: return "Stopped unexpectedly"
        case .failed: return "Failed"
        default: return text(state)
        }
    }

    static func reason(_ state: MCPServerState) -> String? {
        switch state {
        case .restarting(let reason): return "Restarts on next use. \(reason)"
        case .failed(let message): return message
        default: return nil
        }
    }
}
