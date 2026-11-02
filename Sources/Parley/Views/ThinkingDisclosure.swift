import SwiftUI

/// Collapsible model "thinking". Expanded while streaming, collapsed afterwards.
struct ThinkingDisclosure: View {
    let reasoning: String
    let duration: Double?
    let isThinking: Bool
    let isStreaming: Bool

    @ViewState private var expanded: Bool

    init(reasoning: String, duration: Double?, isThinking: Bool, isStreaming: Bool) {
        self.reasoning = reasoning
        self.duration = duration
        self.isThinking = isThinking
        self.isStreaming = isStreaming
        _expanded = State(initialValue: isStreaming)
    }

    private var label: String {
        if isThinking { return "Thinking…" }
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
                    Image(systemName: "brain")
                    Text(label)
                    if isThinking {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(reasoning)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            withAnimation(.easeInOut(duration: 0.2)) { expanded = streaming }
        }
    }
}
