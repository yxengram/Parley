// Oracle for tools/reader-tests/inline-oracle.json: Foundation's own markdown parser with Parley's
// inline options and link rules, run on a list of inputs. MP.inline, PendingLink and ToolDisplay
// below are copies of the app's code (Views/MarkdownView.swift, Views/LinkConfirmation.swift,
// Views/ToolCallViews.swift) with only the SwiftUI styling removed; refresh them if those change.
//
//   swiftc -O tools/reader-tests/oracle.swift -o /tmp/oracle
//   python3 -I -c "import json; print(json.dumps([c['input'] for c in json.load(open('tools/reader-tests/inline-oracle.json'))]))" > /tmp/in.json
//   /tmp/oracle /tmp/in.json > tools/reader-tests/inline-oracle.json
import Foundation
struct PendingLink: Identifiable {
    let id = UUID()
    let url: URL
    let host: String

    init?(_ link: URL) {
        let url = Self.real(link)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: true), Self.readsAsItResolves(host),
              // An address the inert form cannot carry would be a link that does nothing.
              URL(string: url.absoluteString) != nil else { return nil }
        self.url = url
        self.host = ToolDisplay.address(host)
    }

    /// False for a host a browser reads differently. It decodes percent-encoding, so
    /// `good.example%2Eevil.net` belongs to evil.net. It takes a host ending in a number for an IPv4
    /// address in any base, so `010.010.010.010`, which reads as a LAN address, is 8.8.8.8. A host
    /// with neither, such as the missing one in `https:evil.example`, leaves the browser guessing.
    private static func readsAsItResolves(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains("%") else { return false }
        if host.contains(":") { return true } // IPv6
        let labels = host.lowercased().split(separator: ".")
        guard let last = labels.last else { return false }
        let endsInNumber = last.allSatisfy { $0.isASCII && $0.isNumber }
            || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        guard endsInNumber else { return true }
        return labels.count == 4 && labels.allSatisfy { label in
            Int(label).map { (0...255).contains($0) && String($0) == label } ?? false
        }
    }

    /// Rendered text holds this form of a link, never the real one. Whatever the system offers on a
    /// link beside a click (a context menu differs by macOS version) may not go through the app's
    /// OpenURLAction, and an address nothing can open gets nowhere without it.
    static func inert(_ url: URL) -> URL? {
        URL(string: inertPrefix + Data(url.absoluteString.utf8).base64EncodedString())
    }

    private static let inertPrefix = "parley-link:"

    private static func real(_ link: URL) -> URL {
        guard link.absoluteString.hasPrefix(inertPrefix),
              let data = Data(base64Encoded: String(link.absoluteString.dropFirst(inertPrefix.count))),
              let address = String(data: data, encoding: .utf8),
              let url = URL(string: address) else { return link }
        return url
    }

    /// The full destination as it will open. Punycode and percent-encoding stay: read back as
    /// letters they would bring the lookalikes back.
    var address: String { ToolDisplay.address(url.absoluteString) }

    var hasHiddenCharacters: Bool { address != url.absoluteString }
}
enum ToolDisplay {
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
}
enum MP {
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if var attributed = try? AttributedString(markdown: s, options: options) {
            // Inline code: smaller monospaced text on a tinted background (visible in CJK text too).
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
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
func linkJSON(_ p: PendingLink) -> [String: Any] {
    ["url": p.url.absoluteString, "host": p.host, "address": p.address, "hasHiddenCharacters": p.hasHiddenCharacters]
}
let input = try! JSONSerialization.jsonObject(with: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
var out: [[String: Any]] = []
for m in input {
    let a = MP.inline(m)
    var runs: [[String: Any]] = []
    for run in a.runs {
        var f: [String] = []
        if let i = run.inlinePresentationIntent { if i.contains(.emphasized) { f.append("em") }; if i.contains(.stronglyEmphasized) { f.append("strong") }; if i.contains(.code) { f.append("code") }; if i.contains(.strikethrough) { f.append("strike") }; if i.contains(.inlineHTML) { f.append("html") } }
        var link: Any = NSNull()
        if let l = run.link { if let p = PendingLink(l) { link = linkJSON(p) } else { link = "UNDECODABLE" } }
        runs.append(["text": String(a[run.range].characters), "styles": f, "link": link])
    }
    out.append(["input": m, "text": String(a.characters), "runs": runs])
}
let d = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(d)
