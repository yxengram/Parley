import SwiftUI

/// A small, local-only markdown renderer. It never loads remote resources:
/// images in markdown are not fetched, and links open only when clicked
/// (filtered by the OpenURLAction installed in ContentView).
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(Self.headingFont(level))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 4 : 2)
        case .quote(let s):
            Text(MarkdownParser.inline(s))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
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
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case quote(String)
    case code(language: String, code: String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
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
                flushParagraph(); flushQuote()
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
                flushParagraph(); flushQuote()
                i += 1
                continue
            }

            if let (level, content) = heading(trimmed) {
                flushParagraph(); flushQuote()
                blocks.append(.heading(level: level, text: content))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph(); flushQuote()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var q = String(trimmed.dropFirst())
                if q.hasPrefix(" ") { q.removeFirst() }
                quote.append(q)
                i += 1
                continue
            }

            flushQuote()
            paragraph.append(bulletize(line))
            i += 1
        }
        flushParagraph(); flushQuote()
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

    /// "- item" / "* item" / "+ item" → "• item", keeping indentation. Numbered lists stay as-is.
    private static func bulletize(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        for marker in ["- [ ] ", "- [x] ", "- [X] "] where rest.hasPrefix(marker) {
            let box = marker.contains("[ ]") ? "☐ " : "☑ "
            return String(indent) + box + rest.dropFirst(marker.count)
        }
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return String(indent) + "• " + rest.dropFirst(marker.count)
        }
        return line
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: s, options: options) {
            return attributed
        }
        return AttributedString(s)
    }
}
