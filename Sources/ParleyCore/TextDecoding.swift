import Foundation

/// Text that may not be UTF-8: charset labels as browsers read them, what a document says about its
/// own encoding, and a guess when nothing says. Used by `fetch_url`, `read_file` and attachments.
///
/// Labels follow the WHATWG Encoding Standard where it matters for real pages: the GBK family
/// (gb2312, gbk, x-gbk, cp936…) is decoded as GB18030, a superset that also has what Foundation's
/// own GBK lacks (0x80 is €), and Latin-1 labels as Windows-1252.
enum TextDecoding {
    static let gb18030 = encoding(cf: CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    private static let big5 = encoding(cf: CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))

    private static func encoding(cf: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// How far into a document its own declaration is looked for.
    static let declarationWindow = 8 * 1024

    // MARK: Labels

    /// The encoding a charset label names, or nil for one that names nothing known.
    static func encoding(forLabel raw: String) -> String.Encoding? {
        let label = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{0C}\"'")).lowercased()
        guard !label.isEmpty else { return nil }
        switch label {
        case "utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8":
            return .utf8
        case "gb2312", "gbk", "x-gbk", "gb18030", "chinese", "csgb2312", "csiso58gb231280", "gb_2312", "gb_2312-80",
             "iso-ir-58", "cp936", "windows-936", "ms936", "euc-cn":
            return gb18030
        case "big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5":
            return big5
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "us-ascii", "ascii", "ansi_x3.4-1968",
             "windows-1252", "cp1252", "x-cp1252", "cp819", "ibm819":
            return .windowsCP1252
        case "utf-16", "utf-16le", "unicodefeff", "ucs-2", "unicode", "csunicode", "iso-10646-ucs-2":
            return .utf16LittleEndian
        case "utf-16be", "unicodefffe":
            return .utf16BigEndian
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            return cf == kCFStringEncodingInvalidId ? nil : encoding(cf: cf)
        }
    }

    // MARK: Byte order mark

    /// A byte order mark, which beats any label: the encoding and how many bytes it takes.
    static func byteOrderMark(_ data: Data) -> (encoding: String.Encoding, length: Int)? {
        let bytes = Array(data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return (.utf8, 3) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return (.utf16LittleEndian, 2) }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return (.utf16BigEndian, 2) }
        return nil
    }

    // MARK: What a document says

    /// The label a document gives itself near its start: an XML declaration's `encoding`, or for
    /// HTML the first `<meta charset>` or `<meta http-equiv="content-type" content="…charset=…">`
    /// outside a comment. Read as bytes: the document cannot be decoded before this is known.
    static func declaredLabel(in data: Data, isHTML: Bool) -> String? {
        let bytes = Array(data.prefix(declarationWindow))
        if let label = xmlDeclaration(bytes) { return label }
        return isHTML ? metaCharset(bytes) : nil
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D }

    private static func matches(_ bytes: [UInt8], at index: Int, _ word: String) -> Bool {
        let wanted = Array(word.utf8)
        guard index + wanted.count <= bytes.count else { return false }
        for (offset, byte) in wanted.enumerated() where lower(bytes[index + offset]) != byte { return false }
        return true
    }

    private static func find(_ bytes: [UInt8], _ word: String, from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if matches(bytes, at: index, word) { return index }
            index += 1
        }
        return nil
    }

    private static func xmlDeclaration(_ bytes: [UInt8]) -> String? {
        guard matches(bytes, at: 0, "<?xml"), let end = find(bytes, "?>", from: 5),
              let key = find(Array(bytes[..<end]), "encoding", from: 5) else { return nil }
        var index = key + 8
        while index < end, isSpace(bytes[index]) { index += 1 }
        guard index < end, bytes[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        while index < end, isSpace(bytes[index]) { index += 1 }
        guard index < end, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") else { return nil }
        let quote = bytes[index]
        guard let close = bytes[(index + 1)..<end].firstIndex(of: quote) else { return nil }
        return String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
    }

    /// A simplified form of the HTML standard's prescan: comments, other tags and `<!…>`/`<?…>` are
    /// skipped, and each `<meta>`'s attributes are read.
    private static func metaCharset(_ bytes: [UInt8]) -> String? {
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else { index += 1; continue }
            if matches(bytes, at: index, "<!--") {
                guard let end = find(bytes, "-->", from: index + 4) else { return nil }
                index = end + 3
            } else if matches(bytes, at: index, "<meta"), index + 5 < bytes.count, isSpace(bytes[index + 5]) || bytes[index + 5] == UInt8(ascii: "/") {
                let (attributes, next) = readAttributes(bytes, from: index + 5)
                index = next
                if let charset = attributes["charset"], !charset.isEmpty { return charset }
                if attributes["http-equiv"]?.lowercased() == "content-type", let content = attributes["content"],
                   let label = charset(inContent: content) {
                    return label
                }
            } else {
                // Any other tag, end tag, `<!…>` or `<?…>`: on to its `>`, or the end.
                guard let end = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                index = end + 1
            }
        }
        return nil
    }

    /// The attributes of a tag from just after its name, and the index after its `>`.
    private static func readAttributes(_ bytes: [UInt8], from start: Int) -> ([String: String], Int) {
        var attributes: [String: String] = [:]
        var index = start
        func skipSpace() { while index < bytes.count, isSpace(bytes[index]) || bytes[index] == UInt8(ascii: "/") { index += 1 } }
        while true {
            skipSpace()
            guard index < bytes.count else { return (attributes, index) }
            if bytes[index] == UInt8(ascii: ">") { return (attributes, index + 1) }
            var name: [UInt8] = []
            while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: "="), bytes[index] != UInt8(ascii: ">"),
                  bytes[index] != UInt8(ascii: "/") || name.isEmpty {
                name.append(lower(bytes[index]))
                index += 1
            }
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            var value: [UInt8] = []
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                while index < bytes.count, isSpace(bytes[index]) { index += 1 }
                if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    index += 1
                    while index < bytes.count, bytes[index] != quote { value.append(bytes[index]); index += 1 }
                    index += 1
                } else {
                    while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { value.append(bytes[index]); index += 1 }
                }
            }
            let key = String(decoding: name, as: UTF8.self)
            if !key.isEmpty, attributes[key] == nil { attributes[key] = String(decoding: value, as: UTF8.self) }
        }
    }

    /// `text/html; charset=gbk` → `gbk`, as the HTML standard extracts it from a `content` attribute.
    static func charset(inContent content: String) -> String? {
        let bytes = Array(content.utf8)
        var from = 0
        while let found = find(bytes, "charset", from: from) {
            var index = found + 7
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { from = found + 7; continue }
            index += 1
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                let quote = bytes[index]
                guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
                return String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
            }
            let end = bytes[index...].firstIndex { isSpace($0) || $0 == UInt8(ascii: ";") } ?? bytes.count
            return end > index ? String(decoding: bytes[index..<end], as: UTF8.self) : nil
        }
        return nil
    }

    // MARK: Decoding

    /// All or nothing. With `wasCut`, up to three bytes of a character cut at a size cap may go: for
    /// UTF-8 only when they really are the start of a character, so a bad byte near the end is not
    /// dropped as if it were one.
    static func strict(_ data: Data, _ encoding: String.Encoding, wasCut: Bool) -> String? {
        // Every byte is something in Windows-1252 as browsers read it; Foundation's refuses five.
        if encoding == .windowsCP1252 { return windows1252(data) }
        if let text = String(data: data, encoding: encoding) { return text }
        guard wasCut else { return nil }
        for cut in 1...3 where data.count >= cut {
            if encoding == .utf8, !isCutUTF8(data.suffix(cut)) { continue }
            if let text = String(data: data.dropLast(cut), encoding: encoding) { return text }
        }
        return nil
    }

    /// Windows-1252 as the WHATWG Encoding Standard has it: the five bytes it leaves undefined (0x81,
    /// 0x8D, 0x8F, 0x90, 0x9D) are the C1 controls of the same number, so nothing is lost.
    static func windows1252(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data { scalars.append(windows1252Table[Int(byte)]) }
        return String(scalars)
    }

    private static let windows1252Table: [Unicode.Scalar] = (0...255).map { value in
        let byte = UInt8(value)
        if let text = String(bytes: [byte], encoding: .windowsCP1252), let scalar = text.unicodeScalars.first { return scalar }
        return Unicode.Scalar(byte)
    }

    /// UTF-16 that will not decode strictly, read whole with U+FFFD for each bad unit: it cannot be
    /// cut into pieces at single bytes, as a byte of `<` is half of a code unit there.
    static func lossyUTF16(_ data: Data, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let first = UInt16(data[index]), second = UInt16(data[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A lead byte followed by fewer continuation bytes than it needs.
    private static func isCutUTF8(_ tail: Data) -> Bool {
        guard let lead = tail.first else { return false }
        let needed: Int
        switch lead {
        case 0xC2...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF4: needed = 4
        default: return false
        }
        return tail.count < needed && tail.dropFirst().allSatisfy { (0x80...0xBF).contains($0) }
    }

    /// Text with no declaration that is not UTF-8: GB18030 if that reads it cleanly into something
    /// that looks like text. Big5 bytes also fit GB18030's rules, so a Big5 file reads as wrong
    /// characters rather than not at all; browsers set to Chinese guess the same way.
    static func guessedGB18030(_ data: Data, wasCut: Bool) -> String? {
        guard let text = strict(data, gb18030, wasCut: wasCut), looksLikeText(text) else { return nil }
        return text
    }

    /// No NUL and no control character other than tab, newline, form feed and carriage return. Any
    /// byte below 0x20 is that character in GB18030, so binary data read as GB18030 shows them.
    static func looksLikeText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" && $0 != "\u{0C}" || $0.value == 0x7F }
    }
}
