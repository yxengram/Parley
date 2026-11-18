import SwiftUI
import ParleyCore

/// Where a compacted history's summary ends: the messages above it are still here, but requests
/// carry the summary instead (see Compaction). The summary opens in place, as the model sees it.
struct CompactionDivider: View {
    let compaction: ConversationCompaction
    @ViewState private var expanded = false

    static func title(_ compaction: ConversationCompaction) -> String {
        let count = compaction.messageCount ?? 0
        return count > 0
            ? String(localized: "The \(count) messages above are sent as a summary")
            : String(localized: "The messages above are sent as a summary")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                rule
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .font(.caption.weight(.semibold))
                        Image(systemName: "rectangle.compress.vertical")
                        Text(verbatim: Self.title(compaction))
                    }
                    .font(.callout)
                    .foregroundStyle(Hideout.inkSoft)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Earlier messages were summarized to fit the context. Restore the full history in the context popover at the bottom right.")
                .accessibilityLabel(expanded ? "Hide summary" : "Show summary")
                rule
            }
            if expanded {
                Text(compaction.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(Hideout.inkSoft)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Hideout.composerWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var rule: some View {
        Rectangle()
            .fill(Hideout.stitch)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
