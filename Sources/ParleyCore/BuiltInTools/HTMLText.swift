import Foundation

/// The readable text of a web page. One forward pass over the bytes, so a hostile page costs linear
/// time: no regex that can backtrack, and never NSAttributedString, whose HTML importer can load
/// remote resources. Nothing decoded here is read again, so `&lt;script&gt;` stays text.
enum HTMLText {
    static func plain(_ html: String) -> String {
        var scanner = Scanner(source: Array(html.utf8))
        scanner.run()
        let body = scanner.output.text
        guard let title = scanner.title, !title.isEmpty else { return body }
        return body.isEmpty ? title : title + "\n\n" + body
    }

    /// Their content is not text for a reader.
    private static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg"]
    private static let lineBreaks: Set<String> = [
        "br", "li", "tr", "div", "dt", "dd", "option", "section", "article", "header", "footer", "nav", "aside", "main",
        "form", "figure", "figcaption", "address", "details", "summary", "label",
    ]
    private static let paragraphBreaks: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "table", "pre", "blockquote", "hr",
    ]
    private static let cellBreaks: Set<String> = ["td", "th"]
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{AB}", "raquo": "\u{BB}", "bull": "\u{2022}", "middot": "\u{B7}",
        "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}", "times": "\u{D7}", "euro": "\u{20AC}", "pound": "\u{A3}",
    ]
    /// `&` plus the longest entity anyone writes. A bound, so a page of `&&&&` stays linear.
    private static let entityLookahead = 32

    /// Collapses whitespace as text is added.
    private struct Output {
        private var bytes: [UInt8] = []
        private var space = false
        private var breaks = 0

        var text: String { String(decoding: bytes, as: UTF8.self) }

        mutating func addSpace() { space = true }
        mutating func addBreak(_ count: Int) { breaks = max(breaks, count) }

        mutating func add(_ byte: UInt8) {
            if !bytes.isEmpty {
                if breaks > 0 {
                    bytes.append(contentsOf: repeatElement(0x0A, count: breaks))
                } else if space {
                    bytes.append(0x20)
                }
            }
            space = false
            breaks = 0
            bytes.append(byte)
        }

        mutating func add(_ text: String) {
            for byte in text.utf8 {
                if byte == 0x20 { addSpace() } else { add(byte) }
            }
        }
    }

    private struct Scanner {
        let source: [UInt8]
        var index = 0
        var output = Output()
        var title: String?

        mutating func run() {
            while index < source.count {
                switch source[index] {
                case UInt8(ascii: "<"): tag()
                case UInt8(ascii: "&"): entity()
                case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
                    output.addSpace()
                    index += 1
                default:
                    output.add(source[index])
                    index += 1
                }
            }
        }

        private mutating func tag() {
            if matches("<!--", at: index) {
                index = endOfComment(from: index + 2)
                return
            }
            let next = index + 1
            guard next < source.count else {
                output.add(source[index])
                index += 1
                return
            }
            if source[next] == UInt8(ascii: "!") || source[next] == UInt8(ascii: "?") {
                index = (firstIndex(of: UInt8(ascii: ">"), from: next) ?? source.count - 1) + 1
                return
            }
            let closing = source[next] == UInt8(ascii: "/")
            let nameStart = closing ? next + 1 : next
            guard nameStart < source.count, Self.isLetter(source[nameStart]) else {
                // "a < b" is text.
                output.add(source[index])
                index += 1
                return
            }
            var nameEnd = nameStart
            while nameEnd < source.count, Self.isNameByte(source[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: source[nameStart..<nameEnd], as: UTF8.self).lowercased()
            index = endOfTag(from: nameEnd)

            if !closing, name == "title" {
                let text = rawContent(of: name)
                if title == nil { title = Self.plainLine(text) }
            } else if !closing, HTMLText.skippedElements.contains(name) {
                // Only svg can close itself: HTML ignores `/>` on the others, as `<script src=x/>` shows.
                if !(name == "svg" && index >= 2 && source[index - 1] == UInt8(ascii: ">") && source[index - 2] == UInt8(ascii: "/")) {
                    _ = rawContent(of: name)
                }
            } else if HTMLText.paragraphBreaks.contains(name) {
                output.addBreak(2)
            } else if HTMLText.lineBreaks.contains(name) {
                output.addBreak(1)
            } else if HTMLText.cellBreaks.contains(name) {
                output.addSpace()
            }
        }

        /// Past the tag's `>`, which a quoted attribute may contain. A tag that never ends takes the
        /// rest of the page with it, as it does in a browser.
        private func endOfTag(from start: Int) -> Int {
            var quote: UInt8?
            // A quote opens a value only as the first byte after `=`. Anywhere else, an unquoted value
            // included, it is an ordinary byte, or `class=o'brien` would swallow the page.
            var afterEquals = false
            var inUnquoted = false
            var i = start
            while i < source.count {
                let byte = source[i]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: ">") {
                    return i + 1
                } else if inUnquoted {
                    inUnquoted = !Self.isSpace(byte)
                } else if afterEquals {
                    if !Self.isSpace(byte) {
                        afterEquals = false
                        if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { quote = byte } else { inUnquoted = true }
                    }
                } else if byte == UInt8(ascii: "=") {
                    afterEquals = true
                }
                i += 1
            }
            return source.count
        }

        /// The bytes up to `</name`, leaving the cursor past that closing tag. An element that is
        /// never closed ends the scan, so this search runs to the end of the page at most once.
        private mutating func rawContent(of name: String) -> ArraySlice<UInt8> {
            let wanted = Array(name.utf8)
            var i = index
            while i + 2 + wanted.count <= source.count {
                let end = i + 2 + wanted.count
                if source[i] == UInt8(ascii: "<"), source[i + 1] == UInt8(ascii: "/"),
                   zip(source[(i + 2)...], wanted).allSatisfy({ Self.lower($0) == $1 }),
                   // `</scripts>` does not close a script.
                   end == source.count || Self.isSpace(source[end]) || source[end] == UInt8(ascii: "/") || source[end] == UInt8(ascii: ">") {
                    let content = source[index..<i]
                    index = endOfTag(from: end)
                    return content
                }
                i += 1
            }
            let content = source[index...]
            index = source.count
            return content
        }

        private mutating func entity() {
            guard let (text, length) = decodeEntity(at: index) else {
                output.add(source[index])
                index += 1
                return
            }
            output.add(text)
            index += length
        }

        /// The text and how many bytes it replaces.
        private func decodeEntity(at start: Int) -> (String, Int)? {
            let limit = min(source.count, start + HTMLText.entityLookahead)
            var i = start + 1
            guard i < limit else { return nil }
            if source[i] == UInt8(ascii: "#") {
                i += 1
                let hex = i < limit && (source[i] | 0x20) == UInt8(ascii: "x")
                if hex { i += 1 }
                let digits = i
                var value: UInt32 = 0
                while i < limit, let digit = Self.digit(source[i], hex: hex) {
                    // Saturates past the last scalar, however long the number.
                    value = min(value &* (hex ? 16 : 10) &+ digit, 0x110000)
                    i += 1
                }
                guard i > digits else { return nil }
                if i < limit, source[i] == UInt8(ascii: ";") { i += 1 }
                let scalar = value == 0 ? nil : Unicode.Scalar(value)
                return (String(Character(scalar ?? "\u{FFFD}")), i - start)
            }
            while i < limit, Self.isLetter(source[i]) || Self.isDigit(source[i]) { i += 1 }
            guard i < limit, source[i] == UInt8(ascii: ";"),
                  let text = HTMLText.entities[String(decoding: source[(start + 1)..<i], as: UTF8.self)] else { return nil }
            return (text, i + 1 - start)
        }

        private static func plainLine(_ bytes: ArraySlice<UInt8>) -> String {
            var inner = Scanner(source: Array(bytes))
            while inner.index < inner.source.count {
                let byte = inner.source[inner.index]
                if byte == UInt8(ascii: "&") {
                    inner.entity()
                } else {
                    if byte <= 0x20 { inner.output.addSpace() } else { inner.output.add(byte) }
                    inner.index += 1
                }
            }
            return inner.output.text
        }

        private func matches(_ text: String, at start: Int) -> Bool {
            let wanted = Array(text.utf8)
            guard start + wanted.count <= source.count else { return false }
            return zip(source[start...], wanted).allSatisfy { $0 == $1 }
        }

        private func endOfComment(from start: Int) -> Int {
            var i = start
            while i + 2 < source.count {
                if source[i] == UInt8(ascii: "-"), source[i + 1] == UInt8(ascii: "-") {
                    if source[i + 2] == UInt8(ascii: ">") { return i + 3 }
                    // `start` is on the opening dashes, and `--!>` must come after them: `<!--!>` is still open.
                    if i >= start + 2, i + 3 < source.count, source[i + 2] == UInt8(ascii: "!"), source[i + 3] == UInt8(ascii: ">") { return i + 4 }
                }
                i += 1
            }
            return source.count
        }

        private func firstIndex(of byte: UInt8, from start: Int) -> Int? {
            source[start...].firstIndex(of: byte)
        }

        private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D }
        private static func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
        private static func isLetter(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte | 0x20) }
        private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        private static func isNameByte(_ byte: UInt8) -> Bool { isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":") }

        private static func digit(_ byte: UInt8, hex: Bool) -> UInt32? {
            if isDigit(byte) { return UInt32(byte - 0x30) }
            guard hex else { return nil }
            let lowered = byte | 0x20
            return (0x61...0x66).contains(lowered) ? UInt32(lowered - 0x61 + 10) : nil
        }
    }
}
