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
        height > maxHeight ? String(localized: "About \(Int((height / textBlockRowHeight).rounded(.up))) lines. Scroll to see all of them.") : nil
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
        guard let shown else { return String(localized: "Truncated: \(TokenFormat.grouped(total)) characters in all.") }
        return String(localized: "Truncated: showing \(TokenFormat.grouped(shown)) of \(TokenFormat.grouped(total)) characters.")
    }

    static func omittedLine(_ result: ToolCallResult) -> String? {
        guard let omitted = result.omitted, !omitted.isEmpty else { return nil }
        return String(localized: "Not shown to the model: \(omitted.joined(separator: "; ")).")
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
            if isPending { return ToolCallPresentation(glyph: .symbol("hand.raised"), text: String(localized: "Waiting for your approval")) }
            if isActive { return ToolCallPresentation(glyph: .progress, text: String(localized: "Running…")) }
            if replyInProgress { return ToolCallPresentation(glyph: .symbol("clock"), text: String(localized: "Waiting")) }
            return ToolCallPresentation(glyph: .symbol("stop.circle"), text: String(localized: "Interrupted"))
        }
        switch result.callStatus {
        case .completed: return ToolCallPresentation(glyph: .symbol("checkmark"), text: String(localized: "Done"))
        case .toolError: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: String(localized: "Tool error"))
        case .failed: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: String(localized: "Failed"))
        case .timedOut: return ToolCallPresentation(glyph: .symbol("exclamationmark.triangle"), text: String(localized: "Timed out"))
        case .denied: return ToolCallPresentation(glyph: .symbol("hand.raised"), text: String(localized: "Denied"))
        case .cancelled: return ToolCallPresentation(glyph: .symbol("stop.circle"), text: call.startedAt == nil ? String(localized: "Stopped") : String(localized: "Interrupted"))
        case .notCalled: return ToolCallPresentation(glyph: .symbol("xmark"), text: String(localized: "Not called"))
        case nil: return ToolCallPresentation(glyph: .symbol("questionmark"), text: String(localized: "Finished"))
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

    /// Same edge on every launch, unlike `hashValue`.
    private var slipSeed: Int {
        call.id.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) % 997 }
    }

    /// Moss when it worked, danger when it broke, caution when it was cut short for a reason worth
    /// noticing. A call that is only waiting or was stopped stays quiet.
    private var statusColor: Color {
        guard let result = call.result else {
            return presentation.glyph == .symbol("hand.raised") ? Hideout.attention : Hideout.inkSoft
        }
        switch result.callStatus {
        case .completed: return Hideout.moss
        case .toolError, .failed: return Hideout.danger
        case .timedOut, .denied: return Hideout.caution
        case .cancelled, .notCalled, nil: return Hideout.inkSoft
        }
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
                        .foregroundStyle(Hideout.inkSoft)
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(Hideout.inkSoft)
                    Text(verbatim: ToolDisplay.title(call))
                        .fontWeight(.medium)
                        .foregroundStyle(Hideout.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·").foregroundStyle(Hideout.inkFaint)
                    HStack(spacing: 4) {
                        switch presentation.glyph {
                        case .progress: FirefliesIndicator()
                        case .symbol(let name): Image(systemName: name)
                        }
                        Text(verbatim: presentation.text)
                    }
                    .foregroundStyle(statusColor)
                    if let duration = call.result?.duration {
                        Text(verbatim: TokenFormat.seconds(duration))
                            .monospacedDigit()
                            .foregroundStyle(Hideout.inkFaint)
                    }
                }
                .font(.callout)
                .padding(.leading, 15)
                .padding(.trailing, 11)
                .padding(.vertical, 6)
                .paperCard(Hideout.card, seed: slipSeed, radius: 9)
                .overlay(alignment: .leading) {
                    ToolStitch().padding(.vertical, 6).padding(.leading, 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(ToolDisplay.title(call)), \(presentation.text)"))
            .accessibilityHint(isExpanded ? "Hides the arguments and result" : "Shows the arguments and result")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ToolTextBlock(title: String(localized: "Arguments"), text: ToolDisplay.prettyArguments(call.arguments))
                    if call.result != nil || presentation.glyph == .symbol("stop.circle") {
                        ToolTextBlock(title: String(localized: "Result"), text: call.replayResult)
                    }
                    if let result = call.result {
                        ForEach([ToolDisplay.truncationLine(result), ToolDisplay.omittedLine(result)].compactMap { $0 }, id: \.self) { line in
                            Text(verbatim: line)
                                .font(.caption)
                                .foregroundStyle(Hideout.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 13)
                // The slip's stitching carries on down its contents.
                .overlay(alignment: .leading) { ToolStitch() }
                .padding(.leading, 7)
            }
        }
    }
}

/// A short run of thread down the side of a tool slip. Decoration only.
private struct ToolStitch: View {
    private struct Thread: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return p
        }
    }

    var body: some View {
        Thread()
            .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [3, 4]))
            .frame(width: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Hideout.boardInkSoft)
                Spacer(minLength: 0)
                Button {
                    Pasteboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Hideout.boardInkSoft)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy \(title)")
                .accessibilityLabel("Copy \(title)")
            }
            ScrollView {
                Text(verbatim: ToolDisplay.visible(text))
                    .font(.system(size: 12, design: .monospaced))
                    .fontDesign(.monospaced)
                    // The scene's rounded design would otherwise replace the font's own.
                    .fontDesign(.monospaced)
                    .lineSpacing(2)
                    .foregroundStyle(Hideout.boardInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            }
            .scrollIndicators(.visible)
            // The board is dark in both appearances, so its scroller must be the light one.
            .environment(\.colorScheme, .dark)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            if let overflow = ToolDisplay.overflowLine(height: textHeight, maxHeight: maxHeight) {
                Text(verbatim: overflow)
                    .font(.caption)
                    .foregroundStyle(Hideout.boardInkSoft)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .background(Hideout.board, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Inline at the pending call, flat and in the one cool colour so nothing in the room outranks it. No keyboard
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
        VStack(alignment: .leading, spacing: 10) {
            DecisionHeading(title: Text("Allow this tool call?"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(ToolDisplay.line(approval.serverName)) › \(ToolDisplay.line(approval.toolName))")
                    .font(.callout.monospaced().weight(.semibold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(Hideout.ink)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !approval.serverDetail.isEmpty {
                    Text(verbatim: ToolDisplay.line(approval.serverDetail))
                        .font(.callout)
                        .foregroundStyle(Hideout.inkSoft)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if approval.definitionChanged {
                Label("This tool's description or parameters changed since you chose Always Allow.", systemImage: "exclamationmark.triangle.fill")
                    .safetyNotice(.caution)
            }
            if approval.readFromText {
                Label("Read from the model's text, which can repeat tool output, so this call can only be allowed once.", systemImage: "text.quote")
                    .font(.callout)
                    .foregroundStyle(Hideout.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else if approval.asksEveryTime {
                Label("A file or a web page can tell the model what to do next, so this tool asks every time.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Hideout.inkSoft)
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
                            Text(verbatim: approval.definitionLabel)
                        }
                        .font(.callout)
                        .foregroundStyle(Hideout.inkSoft)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showDescription {
                        if let description = approval.description, !description.isEmpty {
                            Text(verbatim: ToolDisplay.visible(String(description.prefix(4000))))
                                .font(.callout)
                                .foregroundStyle(Hideout.inkSoft)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ToolTextBlock(title: String(localized: "Parameters"), text: approval.parameters, maxHeight: 160)
                    }
            }
            ToolTextBlock(title: String(localized: "Arguments"), text: approval.arguments, maxHeight: 220)
            if ToolDisplay.containsHidden(approval.arguments) {
                Label("The arguments contain hidden characters, shown here as \\u{…}.", systemImage: "exclamationmark.triangle.fill")
                    .safetyNotice(.caution)
            }
            HStack(spacing: 8) {
                Button("Deny") { answer(approval.id, .deny) }
                    .buttonStyle(TagButtonStyle())
                    .modifier(AttentionEdge())
                Button("Allow Once") { answer(approval.id, .allowOnce) }
                    .buttonStyle(TagButtonStyle(kind: .primary))
                    .disabled(!armed)
                if approval.offersAlwaysAllow {
                    Button("Always Allow This Tool") { answer(approval.id, .alwaysAllow) }
                        .buttonStyle(TagButtonStyle())
                        .disabled(!armed)
                        .modifier(AttentionEdge(isDimmed: !armed))
                }
            }
            .padding(.top, 2)
        }
        .task(id: approval.id) {
            armed = false
            try? await Task.sleep(nanoseconds: UInt64(Self.armDelay * 1_000_000_000))
            armed = true
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noticeCard(fill: Hideout.attentionWash, edge: Hideout.attention)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Allow this tool call?")
    }
}

/// A server's status as one dot (the settings list and the tools popover).
struct MCPStatusDot: View {
    let state: MCPServerState

    private var color: Color {
        switch state {
        case .ready: return Hideout.moss
        case .stopped: return Hideout.inkFaint
        case .starting, .restarting: return Hideout.caution
        case .failed: return Hideout.danger
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
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .ready: return String(localized: "Ready")
        case .restarting(let reason):
            let shown = MCPErrorText.shown(reason)
            return String(localized: "Stopped unexpectedly, restarts on next use: \(shown)")
        case .failed(let message): return MCPErrorText.shown(message)
        }
    }

    /// The state in a few words, for a row with `reason` below it.
    static func label(_ state: MCPServerState) -> String {
        switch state {
        case .restarting: return String(localized: "Stopped unexpectedly")
        case .failed: return String(localized: "Failed")
        default: return text(state)
        }
    }

    static func reason(_ state: MCPServerState) -> String? {
        switch state {
        case .restarting(let reason):
            let shown = MCPErrorText.shown(reason)
            return String(localized: "Restarts on next use. \(shown)")
        case .failed(let message): return MCPErrorText.shown(message)
        default: return nil
        }
    }
}

// Private on purpose: other surfaces define their own helpers, and these must not collide.
private enum SafetyTone { case caution, danger }

private extension View {
    /// A warning or an error on its own flat strip. Exact wording, no decoration.
    func safetyNotice(_ tone: SafetyTone) -> some View {
        let edge = tone == .danger ? Hideout.danger : Hideout.caution
        return self
            .font(.callout.weight(.medium))
            .foregroundStyle(edge)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .noticeCard(fill: tone == .danger ? Hideout.dangerWash : Hideout.cautionWash, edge: edge, radius: 8)
    }
}


/// The title of something that needs a decision: plain and strong, never lettered.
private struct DecisionHeading: View {
    let title: Text

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Hideout.paper)
                .frame(width: 26, height: 26)
                .background(Hideout.attention, in: Circle())
                .accessibilityHidden(true)
            title
                .font(Hideout.title(16))
                .foregroundStyle(Hideout.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// A soft tag's fill all but vanishes on the attention wash, so Deny and Always Allow get an edge
/// and stay plainly buttons beside Allow Once. Traces TagButtonStyle's own outline.
private struct AttentionEdge: ViewModifier {
    var isDimmed = false

    func body(content: Content) -> some View {
        content.overlay {
            WobblyRect(seed: 11, radius: 10, amplitude: 0.8)
                .strokeBorder(Hideout.attention, lineWidth: 1.25)
                .opacity(isDimmed ? 0.55 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
