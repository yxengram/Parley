import Foundation

// Agent Skills (https://agentskills.io/specification): a folder with a SKILL.md, YAML frontmatter
// (`name`, `description`, optional `license`, `compatibility`, `metadata`, `allowed-tools`) and a
// Markdown body of instructions. Parley reads them leniently, as the client guide asks: a skill that
// breaks a naming rule still loads with a warning, and only one without a description, or with no
// frontmatter at all, is skipped. Nothing in a skill changes what Parley allows: `allowed-tools`
// is ignored, a skill runs no program, and its text reaches the model only through activate_skill.

/// What the model is told about one skill, and where its files are. The path stays in Parley: the
/// catalog and every result use paths relative to the skill's folder.
public struct SkillSummary: Sendable, Equatable, Hashable {
    public var name: String
    public var description: String
    public var directoryPath: String

    public init(name: String, description: String, directoryPath: String) {
        self.name = name
        self.description = description
        self.directoryPath = directoryPath
    }
}

/// One skill found in the skills folder.
public struct Skill: Sendable, Equatable, Identifiable {
    /// The folder's name inside the skills folder: unique there, and what Remove acts on.
    public var id: String { folderName }
    public var folderName: String
    public var directory: URL
    /// What the model calls it. Unique among the skills Parley loaded.
    public var name: String
    public var description: String
    public var license: String?
    public var compatibility: String?
    /// Departures from the specification that did not stop it loading, in the interface language.
    public var warnings: [String]

    public var summary: SkillSummary {
        SkillSummary(name: name, description: description, directoryPath: directory.path)
    }
}

/// A folder in the skills folder that did not load, and why (interface language).
public struct SkillProblem: Sendable, Equatable, Identifiable {
    public var id: String { folderName }
    public var folderName: String
    public var message: String
}

public enum SkillManifest {
    public static let fileName = "SKILL.md"
    /// Larger than any sensible SKILL.md (the guide asks for under 500 lines); a bigger one is refused.
    public static let maxFileBytes = 1024 * 1024
    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    public static let maxCompatibilityLength = 500

    /// The frontmatter's fields and the body, or nil when the file has no frontmatter block.
    public struct Parsed: Equatable {
        /// Top-level scalar fields. A mapping (`metadata`) is in `maps`; a list is left out.
        public var fields: [String: String]
        public var maps: [String: [String: String]]
        /// Everything after the closing `---`, trimmed.
        public var body: String
    }

    /// The spec's rule for `name`: 1 to 64 of a-z, 0-9 and "-", no "-" at either end, no "--".
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength, !name.hasPrefix("-"), !name.hasSuffix("-"),
              !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: Reading a skill

    public enum Outcome: Equatable {
        case skill(name: String, description: String, license: String?, compatibility: String?, warnings: [String])
        case problem(String)
    }

    /// What a SKILL.md says, checked leniently. `folderName` is the folder it sits in.
    public static func read(_ text: String, folderName: String) -> Outcome {
        guard let parsed = parse(text) else {
            return .problem(String(localized: "SKILL.md has no frontmatter: it must start with a line of three dashes, then name and description, then another line of three dashes."))
        }
        let description = oneLine(parsed.fields["description"] ?? "")
        guard !description.isEmpty else {
            return .problem(String(localized: "SKILL.md has no description, so the model could not know when to use it."))
        }
        var warnings: [String] = []
        var name = oneLine(parsed.fields["name"] ?? "")
        if name.isEmpty {
            name = folderName
            warnings.append(String(localized: "SKILL.md has no name, so the folder's name is used."))
        } else if !isValidName(name) {
            warnings.append(String(localized: "The name should be at most 64 lowercase letters, digits and single hyphens."))
        }
        if name != folderName {
            warnings.append(String(localized: "The name does not match the folder's name, \(folderName)."))
        }
        if description.count > maxDescriptionLength {
            warnings.append(String(localized: "The description is longer than 1,024 characters. The model sees only the first 1,024."))
        }
        let compatibility = parsed.fields["compatibility"].map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
        if let compatibility, compatibility.count > maxCompatibilityLength {
            warnings.append(String(localized: "The compatibility note is longer than 500 characters."))
        }
        if let tools = parsed.fields["allowed-tools"], !tools.trimmingCharacters(in: .whitespaces).isEmpty {
            warnings.append(String(localized: "It lists allowed tools. Parley ignores that: tools still ask as they always do."))
        }
        let license = parsed.fields["license"].map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
        return .skill(name: name, description: description, license: license, compatibility: compatibility, warnings: warnings)
    }

    /// The text for the model's catalog: one line, at most `maxDescriptionLength` characters.
    public static func catalogDescription(_ description: String) -> String {
        let line = oneLine(description)
        return line.count > maxDescriptionLength ? String(line.prefix(maxDescriptionLength)) : line
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Frontmatter

    /// A forgiving reader of the YAML that SKILL.md files use: `key: value` lines, quoted values,
    /// `|` and `>` block scalars, plain values that go on over indented lines, and one level of
    /// nested mapping (`metadata`). Like other clients it takes an unquoted value with a colon in it
    /// as it is, which strict YAML would refuse. Lists, anchors and flow collections are skipped.
    public static func parse(_ raw: String) -> Parsed? {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let close = lines.indices.dropFirst().first(where: {
            // A document marker counts only at column 0; an indented one is content.
            var line = Substring(lines[$0])
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return line == "---" || line == "..."
        }) else { return nil }
        let block = Array(lines[1..<close])
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        var maps: [String: [String: String]] = [:]
        var i = 0
        while i < block.count {
            let line = block[i]
            i += 1
            guard indentation(line) == 0, let (key, rest) = keyValue(line) else { continue }
            let value = rest.trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                // A nested mapping or a list: take the indented lines that follow.
                var nested: [String: String] = [:]
                let start = i
                while i < block.count, isBlank(block[i]) || indentation(block[i]) > 0 {
                    if let (k, v) = keyValue(block[i].trimmingCharacters(in: .whitespaces)) {
                        nested[k] = scalar(v.trimmingCharacters(in: .whitespaces))
                    }
                    i += 1
                }
                if !nested.isEmpty {
                    maps[key] = nested
                } else if let plain = plainOnNextLines(Array(block[start..<i])) {
                    fields[key] = plain
                }
                continue
            }
            if let style = value.first, style == "|" || style == ">" {
                var collected: [String] = []
                while i < block.count, isBlank(block[i]) || indentation(block[i]) > 0 {
                    collected.append(block[i])
                    i += 1
                }
                fields[key] = blockScalar(collected, folded: style == ">", keepTrailing: value.contains("+"),
                                          stripTrailing: value.contains("-"))
                continue
            }
            if let quote = value.first, quote == "\"" || quote == "'" {
                var joined = value
                while !isClosed(joined, quote: quote), i < block.count, indentation(block[i]) > 0 || isBlank(block[i]) {
                    joined += " " + block[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                fields[key] = scalar(joined)
                continue
            }
            // A plain value may go on over more-indented lines, folded with spaces.
            var joined = stripComment(value)
            while i < block.count, indentation(block[i]) > 0, !isBlank(block[i]) {
                joined += " " + stripComment(block[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            fields[key] = joined
        }
        return Parsed(fields: fields, maps: maps, body: body)
    }

    /// A plain or quoted scalar that starts on the line after `key:`. Lists are not scalars.
    private static func plainOnNextLines(_ lines: [String]) -> String? {
        let parts = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first, !first.hasPrefix("- "), first != "-", !first.hasPrefix("#") else { return nil }
        if let quote = first.first, quote == "\"" || quote == "'" { return scalar(parts.joined(separator: " ")) }
        return parts.map(stripComment).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// `key: rest`, for a key of letters, digits, "-" and "_". Comments and list items are not keys.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let rest = line[line.index(after: colon)...]
        // "key:value" with no space is a plain value in YAML only when it is a URL-like word; take it.
        return (key, String(rest))
    }

    /// " #" starts a comment in a plain value.
    private static func stripComment(_ value: String) -> String {
        guard let range = value.range(of: " #") else { return value }
        return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The index of the quote that closes `value`, which starts with `quote`.
    private static func closingQuote(_ value: String, quote: Character) -> String.Index? {
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let c = value[index]
            let next = value.index(after: index)
            if quote == "\"", c == "\\" {
                guard next < value.endIndex else { return nil }
                index = value.index(after: next)
                continue
            }
            if c == quote {
                if quote == "'", next < value.endIndex, value[next] == "'" {
                    index = value.index(after: next)
                    continue
                }
                return index
            }
            index = next
        }
        return nil
    }

    private static func isClosed(_ value: String, quote: Character) -> Bool {
        closingQuote(value, quote: quote) != nil
    }

    /// A quoted or plain scalar's value.
    private static func scalar(_ value: String) -> String {
        if let quote = value.first, quote == "\"" || quote == "'", let end = closingQuote(value, quote: quote) {
            let after = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            if after.isEmpty || after.hasPrefix("#") {
                let inner = String(value[value.index(after: value.startIndex)..<end])
                return quote == "'" ? inner.replacingOccurrences(of: "''", with: "'") : unescape(inner)
            }
        }
        return stripComment(value)
    }

    private static func unescape(_ inner: String) -> String {
        let chars = Array(inner)
        var out = ""
        var i = 0
        func hex(_ count: Int) -> UInt32? {
            guard i + count <= chars.count else { return nil }
            let code = UInt32(String(chars[i..<i + count]), radix: 16)
            if code != nil { i += count }
            return code
        }
        while i < chars.count {
            let c = chars[i]
            i += 1
            guard c == "\\", i < chars.count else { out.append(c); continue }
            let e = chars[i]
            i += 1
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "x", "u", "U":
                guard var code = hex(e == "x" ? 2 : e == "u" ? 4 : 8) else { break }
                // A JSON-style surrogate pair is one character.
                if (0xD800...0xDBFF).contains(code), i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "u" {
                    let saved = i
                    i += 2
                    if let low = hex(4), (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = saved
                    }
                }
                if let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            default: out.append(e)
            }
        }
        return out
    }

    /// A `|` (literal) or `>` (folded) block, its indentation taken from the first line with text.
    private static func blockScalar(_ lines: [String], folded: Bool, keepTrailing: Bool, stripTrailing: Bool) -> String {
        let indent = lines.first(where: { !isBlank($0) }).map(indentation) ?? 0
        let content = lines.map { isBlank($0) ? "" : String($0.dropFirst(min(indent, indentation($0)))) }
        var text: String
        if folded {
            var paragraphs: [String] = []
            var current: [String] = []
            for line in content {
                if line.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                } else {
                    current.append(line)
                }
            }
            paragraphs.append(current.joined(separator: " "))
            text = paragraphs.joined(separator: "\n")
        } else {
            text = content.joined(separator: "\n")
        }
        if stripTrailing {
            while text.hasSuffix("\n") { text.removeLast() }
        } else if !keepTrailing {
            while text.hasSuffix("\n") { text.removeLast() }
            text += "\n"
        }
        return text.trimmingCharacters(in: .newlines).isEmpty ? "" : text
    }
}
