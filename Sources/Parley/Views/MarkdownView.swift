import SwiftUI

/// A small, local-only markdown renderer. It never loads remote resources:
/// images in markdown are not fetched, and links are inert until the OpenURLAction installed in
/// ContentView has shown the real address and the user has agreed.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        // Long replies read in the plain system face; links take the on-paper ember.
        .fontDesign(.default)
        .tint(Hideout.emberText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(Self.headingFont(level))
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .padding(.top, level <= 2 ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(Hideout.emberText)
                            .monospacedDigit()
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let s):
            Text(MarkdownParser.inline(s))
                .foregroundStyle(Hideout.inkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Hideout.stitch).frame(width: 3)
                }
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .rule:
            StitchedRule()
                .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [6, 5]))
                .frame(height: 1.25)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
    }

    /// A line of quilt stitching across the page, for a markdown rule.
    private struct StitchedRule: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(Hideout.boardInkSoft)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Hideout.boardInkSoft)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy code")
                .accessibilityLabel("Copy Code")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    // An inherited font design would otherwise replace the monospaced face.
                    .fontDesign(.monospaced)
                    .foregroundStyle(Hideout.boardInk)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
        // A chalkboard in both appearances. The edge barely wanders: its points shift as a
        // streaming block grows.
        .background {
            WobblyRect(seed: 5, radius: 12, amplitude: 0.8)
                .fill(Hideout.board)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
        }
    }
}

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListItem])
    case quote(String)
    case code(language: String, code: String)
    case rule
}

struct ListItem: Hashable {
    /// Nesting level (0 = top).
    var indent: Int
    /// "•", "◦", "1.", "☐", "☑"…
    var marker: String
    var text: String
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var list: [ListItem] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushList() {
            if !list.isEmpty {
                blocks.append(.list(list))
                list.removeAll()
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote.removeAll()
            }
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (``` or ~~~). An unclosed fence runs to the end (streaming).
            if let fence = fenceMarker(trimmed) {
                flushParagraph(); flushQuote(); flushList()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.first!))).isEmpty {
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang, code: codeLines.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); flushQuote(); flushList()
                i += 1
                continue
            }

            if let (level, content) = heading(trimmed) {
                flushParagraph(); flushQuote(); flushList()
                blocks.append(.heading(level: level, text: content))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph(); flushQuote(); flushList()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                list.append(item)
                i += 1
                continue
            }

            // An indented line right after a list item continues that item.
            if !list.isEmpty, line.first == " " || line.first == "\t" {
                list[list.count - 1].text += " " + trimmed
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                var q = String(trimmed.dropFirst())
                if q.hasPrefix(" ") { q.removeFirst() }
                quote.append(q)
                i += 1
                continue
            }

            flushQuote(); flushList()
            paragraph.append(line)
            i += 1
        }
        flushParagraph(); flushQuote(); flushList()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        while content.hasSuffix("#") { content.removeLast() }
        return (hashes.count, content.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// "- item", "* item", "+ item", "1. item", "1) item", "- [ ] task"; nil for other lines.
    static func listItem(_ line: String) -> ListItem? {
        let lead = line.prefix { $0 == " " || $0 == "\t" }
        let width = lead.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let level = min(width / 2, 5)
        let rest = line.dropFirst(lead.count)
        for (marker, box) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- [X] ", "☑"), ("* [ ] ", "☐"), ("* [x] ", "☑")] where rest.hasPrefix(marker) {
            return ListItem(indent: level, marker: box, text: String(rest.dropFirst(marker.count)))
        }
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            let bullet = ["•", "◦", "▪"][min(level, 2)]
            return ListItem(indent: level, marker: bullet, text: String(rest.dropFirst(marker.count)))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                return ListItem(indent: level, marker: "\(digits)\(sep)", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if var attributed = try? AttributedString(markdown: s, options: options) {
            // Inline code: smaller monospaced text on a tinted background (visible in CJK text too).
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
                attributed[run.range].backgroundColor = Hideout.paperDeep
            }
            // A link Parley would refuse is plain text; the rest stay links in name only.
            for run in attributed.runs {
                guard let link = run.link else { continue }
                attributed[run.range].link = PendingLink(link).flatMap { PendingLink.inert($0.url) }
            }
            return attributed
        }
        return AttributedString(s)
    }
}
