import AppKit
import SwiftUI
import ParleyCore

/// Shared layout constants.
enum Layout {
    /// Reading width for messages and the composer (about 80–90 characters of body text).
    static let contentMaxWidth: CGFloat = 740
}

// MARK: - Focused conversation (drives the Conversation and Message menus)

// Defined without the @Entry macro: SwiftUI's macros ship only with Xcode, not the CLT.
struct ActiveSessionKey: FocusedValueKey {
    typealias Value = ConversationSession
}

extension FocusedValues {
    var activeSession: ConversationSession? {
        get { self[ActiveSessionKey.self] }
        set { self[ActiveSessionKey.self] = newValue }
    }
}

// MARK: - Main window

@MainActor
enum MainWindow {
    /// Brings the main window forward (reopening it if it was closed) through its
    /// Window menu item, which SwiftUI adds for the single `Window` scene.
    static func showViaMenu() {
        guard let menu = NSApp.windowsMenu else { return }
        if let index = menu.items.firstIndex(where: { $0.title == "Parley" && $0.action != nil }) {
            menu.performActionForItem(at: index)
        }
    }

    static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { w in
            w.isVisible && w.styleMask.contains(.titled) && w.sheetParent == nil
                && !(w.identifier?.rawValue ?? "").contains("Settings")
                && !(w.identifier?.rawValue ?? "").contains("help")
        }
    }
}

// MARK: - Error presentation

/// Turns a stored error string (what ParleyCore's errors describe themselves as) into a
/// readable title, an optional detail line and hints. Rendering only: the stored text is unchanged.
struct ErrorPresentation: Equatable {
    var title: String
    var detail: String?
    /// e.g. "HTTP 503".
    var status: String?
    /// The full original text, when it says more than the title.
    var raw: String?
    /// The fix is in Settings (API key, base URL, provider, model).
    var suggestsSettings = false

    init(title: String, detail: String? = nil, status: String? = nil, raw: String? = nil, suggestsSettings: Bool = false) {
        self.title = title
        self.detail = detail
        self.status = status
        self.raw = raw
        self.suggestsSettings = suggestsSettings
    }

    static func make(_ error: String, providerName: String? = nil, baseURL: String? = nil) -> ErrorPresentation {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = providerName.map { "\($0)" } ?? "the server"
        let host = baseURL.flatMap { URLComponents(string: $0)?.host }
        let place = host.map { "\(server) at \($0)" } ?? server

        if let (status, body) = splitHTTP(text) {
            let message = serverMessage(body)
            let statusText = "HTTP \(status)"
            switch status {
            case 401, 403:
                return ErrorPresentation(
                    title: "The server rejected the API key",
                    detail: message ?? "Check the API key for \(server) in Settings.",
                    status: statusText, raw: text, suggestsSettings: true)
            case 404:
                return ErrorPresentation(
                    title: "Model or endpoint not found",
                    detail: message.map { "Check the model ID and the base URL. The server said: \($0)" }
                        ?? "Check the model ID and the base URL (it usually ends in /v1).",
                    status: statusText, raw: text, suggestsSettings: true)
            case 429:
                return ErrorPresentation(
                    title: "Too many requests",
                    detail: message ?? "The server is rate limiting. Wait a moment and try again.",
                    status: statusText, raw: text)
            case 500...599:
                return ErrorPresentation(
                    title: message ?? "The server had a problem",
                    detail: message == nil ? "Try again in a moment." : nil,
                    status: statusText, raw: text)
            default:
                return ErrorPresentation(
                    title: message ?? "The server rejected the request",
                    status: statusText, raw: text)
            }
        }
        if text.hasPrefix("API error: ") {
            return ErrorPresentation(
                title: String(text.dropFirst("API error: ".count)), raw: nil,
                suggestsSettings: text.contains(ChatClient.missingVersionPathHint))
        }
        let lower = text.lowercased()
        if lower.contains("could not connect to the server") || lower.contains("connection refused")
            || lower.contains("hostname could not be found") || lower.contains("network connection was lost")
            || lower.contains("appears to be offline") {
            return ErrorPresentation(
                title: "Can't reach \(place)",
                detail: "Is the server running? \(text)",
                raw: nil, suggestsSettings: true)
        }
        if lower.contains("timed out") {
            return ErrorPresentation(title: "\(server.prefix(1).uppercased() + server.dropFirst()) took too long to respond", detail: text)
        }
        if text.hasPrefix("No model selected") || text.hasPrefix("No API provider") || text.hasPrefix("Invalid API base URL") {
            return ErrorPresentation(title: text, suggestsSettings: true)
        }
        return ErrorPresentation(title: text)
    }

    /// "HTTP 503: body" → (503, "body").
    static func splitHTTP(_ text: String) -> (Int, String)? {
        guard text.hasPrefix("HTTP ") else { return nil }
        let rest = text.dropFirst(5)
        let digits = rest.prefix { $0.isNumber }
        guard let status = Int(digits) else { return nil }
        var body = rest.dropFirst(digits.count)
        if body.hasPrefix(":") { body = body.dropFirst() }
        return (status, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `{"error":{"message":…}}`, `{"error":"…"}` or `{"message":…}`; plain short text as is.
    static func serverMessage(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = object["error"] as? [String: Any], let m = err["message"] as? String, !m.isEmpty { return m }
            if let m = object["error"] as? String, !m.isEmpty { return m }
            if let m = object["message"] as? String, !m.isEmpty { return m }
            if let m = object["detail"] as? String, !m.isEmpty { return m }
            return nil
        }
        // Not JSON (an HTML error page, say): only use short single-line text.
        if trimmed.count <= 200, !trimmed.contains("<"), !trimmed.contains("\n") { return trimmed }
        return nil
    }
}

// MARK: - Shake

/// Horizontal shake, e.g. for a wrong password. Animate `shakes` to a new integer.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}
