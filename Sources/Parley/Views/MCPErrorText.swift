import Foundation
import ParleyCore

/// MCPError's text stays English in ParleyCore: its summary goes into tool results and saved notes,
/// and the model reads it. Where the interface shows that text (the server status in Settings > MCP,
/// the tools popover, tool notes, the import sheet), the known sentences are shown in the interface
/// language; anything else (a server's own message, a log line) is shown as it is.
enum MCPErrorText {
    static func shown(_ text: String) -> String {
        // A failed start carries the last lines of the server's log after the first line.
        guard let newline = text.firstIndex(of: "\n") else { return line(text) }
        return line(String(text[..<newline])) + text[newline...]
    }

    private static let seeLog = " See its log in Settings > MCP."

    private static func line(_ text: String) -> String {
        if text.hasSuffix(seeLog), text.count > seeLog.count {
            let first = sentence(String(text.dropLast(seeLog.count)))
            return ErrorPresentation.sentences(first, String(localized: "See its log in Settings > MCP."))
        }
        return sentence(text)
    }

    private static func sentence(_ text: String) -> String {
        if let fixed = fixedSentences[text] { return fixed() }
        if let middle = between(text, "Could not find ", ". Install it, or give its full path in Settings > MCP.") {
            if let open = middle.range(of: " (it comes with "), middle.hasSuffix(")") {
                let program = String(middle[..<open.lowerBound])
                let source = String(middle[open.upperBound...].dropLast())
                return String(localized: "Could not find \(program) (it comes with \(source)). Install it, or give its full path in Settings > MCP.")
            }
            return String(localized: "Could not find \(middle). Install it, or give its full path in Settings > MCP.")
        }
        if let middle = between(text, "Could not find ", ". Use an absolute path, or set PATH in this server's environment."),
           let searched = middle.range(of: ". Searched: ") {
            let program = String(middle[..<searched.lowerBound])
            let folders = String(middle[searched.upperBound...])
            return String(localized: "Could not find \(program). Searched: \(folders). Use an absolute path, or set PATH in this server's environment.")
        }
        if let path = between(text, "", " exists but is not a program Parley can run.") {
            return String(localized: "\(path) exists but is not a program Parley can run.")
        }
        if let status = between(text, "The server stopped (status ", ")."), status.allSatisfy({ $0 == "-" || $0.isNumber }) {
            return String(localized: "The server stopped (status \(status)).")
        }
        if let seconds = between(text, "The server did not answer within ", " seconds."), seconds.allSatisfy(\.isNumber) {
            return String(localized: "The server did not answer within \(seconds) seconds.")
        }
        if let times = between(text, "The server stopped ", " times in a minute. Press Connect in Settings > MCP to try again."),
           times.allSatisfy(\.isNumber) {
            return String(localized: "The server stopped \(times) times in a minute. Press Connect in Settings > MCP to try again.")
        }
        if let name = between(text, "The header ", " has an empty name or a line break, so it cannot be sent.") {
            return String(localized: "The header \(name) has an empty name or a line break, so it cannot be sent.")
        }
        if let status = between(text, "The server refused the request (HTTP ", "). Check your access to this server and any headers set for it.") {
            return String(localized: "The server refused the request (HTTP \(status)). Check your access to this server and any headers set for it.")
        }
        if let status = between(text, "The server refused the request (HTTP ", "). Check this server's Authorization header. Sign-in needs https.") {
            return String(localized: "The server refused the request (HTTP \(status)). Check this server's Authorization header. Sign-in needs https.")
        }
        if let version = between(text, "The server speaks an MCP version Parley does not support (", ").") {
            return String(localized: "The server speaks an MCP version Parley does not support (\(version)).")
        }
        // The server's or the system's own words follow the colon; they are shown as they are.
        if let message = between(text, "The server reported an error: ", "") {
            return String(localized: "The server reported an error: \(message)")
        }
        if let rest = between(text, "The server reported an error (", ""), let close = rest.range(of: "): ") {
            let code = String(rest[..<close.lowerBound])
            let message = String(rest[close.upperBound...])
            return String(localized: "The server reported an error (\(code)): \(message)")
        }
        if let why = between(text, "Could not start the server: ", "") {
            return String(localized: "Could not start the server: \(why)")
        }
        return ErrorPresentation.shownSystemText(text)
    }

    private static let fixedSentences: [String: () -> String] = [
        "The server's program cannot be run. Check it in Settings > MCP.":
            { String(localized: "The server's program cannot be run. Check it in Settings > MCP.") },
        "The command contains spaces. Put the program in Command and the rest under Arguments.":
            { String(localized: "The command contains spaces. Put the program in Command and the rest under Arguments.") },
        "The server stopped (status 0). This program may not be an MCP server.":
            { String(localized: "The server stopped (status 0). This program may not be an MCP server.") },
        "This server needs you to sign in. Press Sign In in Settings > MCP, or add a static Authorization header if the server accepts one.":
            { String(localized: "This server needs you to sign in. Press Sign In in Settings > MCP, or add a static Authorization header if the server accepts one.") },
        "This server needs more permission for that. Press Sign In in Settings > MCP to grant it.":
            { String(localized: "This server needs more permission for that. Press Sign In in Settings > MCP to grant it.") },
        "The server sent a message over 16 MB.": { String(localized: "The server sent a message over 16 MB.") },
        "The connection closed before the server answered.": { String(localized: "The connection closed before the server answered.") },
        "The server no longer knows this session.": { String(localized: "The server no longer knows this session.") },
        "The server's URL is not a valid http or https URL.": { String(localized: "The server's URL is not a valid http or https URL.") },
        "This server is turned off.": { String(localized: "This server is turned off.") },
        "This server is no longer configured.": { String(localized: "This server is no longer configured.") },
        "The tool asked for input Parley does not support.": { String(localized: "The tool asked for input Parley does not support.") },
        "This server was stopped.": { String(localized: "This server was stopped.") },
    ]

    /// The part between `prefix` and `suffix`, when `text` is exactly that.
    private static func between(_ text: String, _ prefix: String, _ suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count > prefix.count + suffix.count else { return nil }
        return String(text.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
