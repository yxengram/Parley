import SwiftUI

/// Collapsible model "thinking". Expanded while streaming, collapsed afterwards.
struct ThinkingDisclosure: View {
    let reasoning: String
    let duration: Double?
    let isThinking: Bool
    let isStreaming: Bool
    /// When the live reasoning started (streaming only), for the running seconds count.
    var startedAt: Date? = nil

    @ViewState private var expanded: Bool

    /// While streaming, only the tail of long reasoning is shown, so the reply below stays in view.
    private static let streamingMaxHeight: CGFloat = 200

    init(reasoning: String, duration: Double?, isThinking: Bool, isStreaming: Bool, startedAt: Date? = nil) {
        self.reasoning = reasoning
        self.duration = duration
        self.isThinking = isThinking
        self.isStreaming = isStreaming
        self.startedAt = startedAt
        _expanded = State(initialValue: isStreaming)
    }

    private var finishedLabel: String {
        if let duration { return "Thought for \(Self.format(duration))" }
        return isStreaming ? "Thinking…" : "Thoughts"
    }

    static func format(_ seconds: Double) -> String {
        if seconds < 1 { return "less than a second" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m) min \(s) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Image(systemName: "ellipsis.bubble")
                    label
                    if isThinking {
                        FirefliesIndicator()
                            .scaleEffect(0.65)
                            .frame(width: 38, height: 12)
                    }
                }
                .font(.callout)
                .foregroundStyle(Hideout.inkSoft)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide thinking" : "Show thinking")

            if expanded {
                reasoningText
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        WhisperRule()
                            .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5.5]))
                            .frame(width: 2)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, 5)
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            withAnimation(.easeInOut(duration: 0.2)) { expanded = streaming }
        }
    }

    @ViewBuilder
    private var label: some View {
        if isThinking, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Thinking… \(Int(max(0, context.date.timeIntervalSince(startedAt))))\u{2009}s")
                    .monospacedDigit()
            }
        } else if isThinking {
            Text("Thinking…")
        } else {
            Text(finishedLabel)
        }
    }

    @ViewBuilder
    private var reasoningText: some View {
        // DESIGN.md: secondary, monospaced-ish; at 12 pt it stays smaller than the reply text.
        let text = Text(reasoning)
            .font(.system(size: 12, design: .monospaced))
            .fontDesign(.monospaced)
            .lineSpacing(2)
            .foregroundStyle(Hideout.inkSoft)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if isStreaming {
            // Pinned to the newest lines, faded at the top when cut.
            text
                .frame(maxHeight: Self.streamingMaxHeight, alignment: .bottom)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(reasoning.count > 400 ? 0 : 1), .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                        Color.black
                    }
                }
        } else {
            text
        }
    }

    /// The dotted line down the side of a whisper.
    private struct WhisperRule: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}
