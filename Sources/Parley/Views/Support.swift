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
    /// False when retrying unchanged can only fail the same way (a request refused before sending).
    var retryable = true

    init(title: String, detail: String? = nil, status: String? = nil, raw: String? = nil, suggestsSettings: Bool = false,
         retryable: Bool = true) {
        self.title = title
        self.detail = detail
        self.status = status
        self.raw = raw
        self.suggestsSettings = suggestsSettings
        self.retryable = retryable
    }

    /// A context error says nothing of tools, which may be what filled the context.
    func naming(toolDefinitionTokens tokens: Int?, in error: String) -> ErrorPresentation {
        guard let tokens, tokens > 0, ContextBudget.contextLength(fromError: error) != nil || error.lowercased().contains("context") else {
            return self
        }
        var out = self
        let grouped = TokenFormat.grouped(tokens)
        let note = String(localized: "Tool definitions take about \(grouped) tokens of it. Turn off servers or tools you do not need with the wrench button (⇧⌘T).")
        out.detail = detail.map { Self.sentences($0, note) } ?? note
        return out
    }

    /// Joins whole sentences: a space after English ones, nothing after a Chinese full stop.
    static func sentences(_ parts: String?...) -> String {
        var out = ""
        for part in parts.compactMap({ $0 }) where !part.isEmpty {
            if let last = out.last, !"。！？；：）」”".contains(last) { out += " " }
            out += part
        }
        return out
    }

    /// Foundation's own description of a URL error follows the interface language, and an error
    /// without one reads "(NSURLErrorDomain error -1004.)" (zh: "（NSURLErrorDomain错误-1004。）").
    /// Stored errors may be in either language, so both are recognized.
    static let unreachablePhrases = [
        "could not connect to the server", "connection refused", "hostname could not be found",
        "network connection was lost", "appears to be offline",
        // CFNetwork's zh_CN text for -1004, -1003, -1005, -1009 and its offline notice.
        "无法连接服务器", "未能连接到服务器", "未能找到使用指定主机名的服务器", "网络连接已中断",
        "似乎已断开与互联网的连接", "似乎已断开互联网连接",
    ]
    static let timeoutPhrases = ["timed out", "请求超时", "网关超时"]

    /// SystemErrorText's English sentences, as the interface shows them (zh: CFNetwork's wording).
    static var systemSentences: [(english: String, shown: String)] {
        [
            ("The request timed out.", String(localized: "The request timed out.")),
            ("A server with the specified hostname could not be found.",
             String(localized: "A server with the specified hostname could not be found.")),
            ("Could not connect to the server.", String(localized: "Could not connect to the server.")),
            ("The network connection was lost.", String(localized: "The network connection was lost.")),
            ("The Internet connection appears to be offline.", String(localized: "The Internet connection appears to be offline.")),
            ("An SSL error has occurred and a secure connection to the server cannot be made.",
             String(localized: "An SSL error has occurred and a secure connection to the server cannot be made.")),
        ]
    }

    /// A stored error with its system sentences in the interface language (unchanged in English).
    static func shownSystemText(_ text: String) -> String {
        systemSentences.reduce(text) { out, sentence in
            out.replacingOccurrences(of: sentence.english, with: sentence.shown)
        }
    }

    /// The NSURLErrorDomain code in Foundation's generic description ("… NSURLErrorDomain error -1004 …").
    static func urlErrorCode(in text: String) -> Int? {
        guard let range = text.range(of: "NSURLErrorDomain") else { return nil }
        let rest = text[range.upperBound...].prefix(16)
        guard let minus = rest.firstIndex(of: "-") else { return nil }
        let digits = rest[rest.index(after: minus)...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits).map { -$0 }
    }

    static func isUnreachable(_ text: String) -> Bool {
        let lower = text.lowercased()
        if unreachablePhrases.contains(where: { lower.contains($0) }) { return true }
        return [-1003, -1004, -1005, -1009].contains(urlErrorCode(in: text) ?? 0)
    }

    static func isTimeout(_ text: String) -> Bool {
        let lower = text.lowercased()
        return timeoutPhrases.contains(where: { lower.contains($0) }) || urlErrorCode(in: text) == -1001
    }

    /// `serverKind` is what the app learned about the server (only a few messages need it; the
    /// Strata texts below are recognized by their wording). `partialReply`: the failed reply
    /// already shows some text or thinking.
    static func make(_ error: String, providerName: String? = nil, baseURL: String? = nil,
                     serverKind: InferenceServerKind? = nil, partialReply: Bool = false) -> ErrorPresentation {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = providerName.map { "\($0)" } ?? String(localized: "the server")
        let host = baseURL.flatMap { URLComponents(string: $0)?.host }
        let place = host.map { String(localized: "\(server) at \($0)") } ?? server
        let isStrata = serverKind == .strata

        if let (status, rawBody) = splitHTTP(text) {
            let statusText = "HTTP \(status)"
            // Cloudflare's own pages first: a challenge is a 403 that is not about the API key, and
            // a 52x page says more than "the server had a problem".
            if let cloudflare = CloudflareError.parse(status: status, body: rawBody) {
                var p = cloudflarePresentation(cloudflare, server: server, isStrata: isStrata)
                p.status = statusText
                p.raw = "HTTP \(status): \(cloudflare.summary)"
                return p
            }
            // Pages stored before Parley summarized HTML: never show the markup.
            let body = sanitizedBody(rawBody)
            let text = body == rawBody ? text : "HTTP \(status): \(body)"
            if (300..<400).contains(status) {
                return redirectPresentation(status: status, body: body, server: server, baseURL: baseURL, raw: text)
            }
            let message = serverMessage(body)
            if let message, var strata = strataPresentation(message) {
                strata.status = statusText
                strata.raw = text
                return strata
            }
            switch status {
            case 401, 403:
                return ErrorPresentation(
                    title: String(localized: "The server rejected the API key"),
                    detail: isStrata
                        ? String(localized: "Check the API key for \(server) in Settings. Strata shows its keys (sk-strata-…) on its Serving page.")
                        : message ?? String(localized: "Check the API key for \(server) in Settings."),
                    status: statusText, raw: text, suggestsSettings: true)
            // Strata's shared port could not reach its engine (Node's "fetch failed": stopped, or a
            // cold load that took too long). Other Node-based proxies send the same text.
            case 502 where isStrata && message == "fetch failed":
                return ErrorPresentation(
                    title: String(localized: "Strata's engine did not answer"),
                    detail: String(localized: "The model may still be loading (a cold start can take several minutes), or the engine stopped. Retry in a moment."),
                    status: statusText, raw: text)
            // Strata's shared port: a failure while reading the request, most often a body over 12 MiB.
            case 500 where isStrata && body == "Request failed":
                return ErrorPresentation(
                    title: String(localized: "Strata could not read the request"),
                    detail: String(localized: "Its shared port takes requests up to 12 MB, and images are sent again with every message. Remove images, or fork from a message before the first one, then retry."),
                    status: statusText, raw: text)
            case 404:
                return ErrorPresentation(
                    title: String(localized: "Model or endpoint not found"),
                    detail: message.map { String(localized: "Check the model ID and the base URL. The server said: \($0)") }
                        ?? String(localized: "Check the model ID and the base URL (it usually ends in /v1)."),
                    status: statusText, raw: text, suggestsSettings: true)
            case 429:
                return ErrorPresentation(
                    title: String(localized: "Too many requests"),
                    detail: message ?? String(localized: "The server is rate limiting. Wait a moment and try again."),
                    status: statusText, raw: text)
            case 500...599:
                return ErrorPresentation(
                    title: message ?? String(localized: "The server had a problem"),
                    detail: message == nil ? String(localized: "Try again in a moment.") : nil,
                    status: statusText, raw: text)
            default:
                return ErrorPresentation(
                    title: message ?? String(localized: "The server rejected the request"),
                    status: statusText, raw: text)
            }
        }
        if let interruption = StreamInterruption.parse(text) {
            return interruptedPresentation(interruption, server: server, isStrata: isStrata, partialReply: partialReply, raw: text)
        }
        if text.hasPrefix("API error: ") {
            let message = String(text.dropFirst("API error: ".count))
            if let size = ChatClient.requestTooLarge(in: message) {
                let bytes = size.bytes, limit = size.limit
                return ErrorPresentation(
                    title: String(localized: "Request too large for \(server) (\(bytes) of \(limit))"),
                    detail: String(localized: "Images are sent again with every message, so this conversation stays too large. Fork from a message before the first image, or start a new chat."),
                    raw: text, retryable: false)
            }
            // Errors inside a started stream (Strata sends them as data: {"error":…}).
            if var strata = strataPresentation(message) {
                strata.raw = text
                return strata
            }
            return ErrorPresentation(
                title: message, raw: nil,
                suggestsSettings: text.contains(ChatClient.missingVersionPathHint))
        }
        // A stored system sentence is fixed English (SystemErrorText): shown in the interface language.
        let shown = shownSystemText(text)
        if isUnreachable(text) {
            return ErrorPresentation(
                title: String(localized: "Can't reach \(place)"),
                detail: isStrata && host.map(ChatClient.isLocalHost) ?? false
                    ? String(localized: "Is Strata running, with sharing on the network turned on? It may also be using another port now (Strata picks a free one when its usual port is taken). \(shown)")
                    : isStrata
                    ? String(localized: "Is this Mac online, and is Strata (and its tunnel, if any) running? \(shown)")
                    : String(localized: "Is the server running? \(shown)"),
                raw: nil, suggestsSettings: true)
        }
        if isTimeout(text) {
            let Server = server.prefix(1).uppercased() + server.dropFirst()
            return ErrorPresentation(title: String(localized: "\(Server) took too long to respond"), detail: shown)
        }
        if text.hasPrefix("No model selected") || text.hasPrefix("No API provider") || text.hasPrefix("Invalid API base URL") {
            return ErrorPresentation(title: settingsErrorTitle(text), suggestsSettings: true)
        }
        if let status = keychainStatus(text).map(String.init) {
            return ErrorPresentation(title: String(localized: "Keychain error (OSStatus \(status))."))
        }
        return ErrorPresentation(title: shown)
    }

    /// The app's own stored texts for a missing provider or model and a bad base URL (English on
    /// disk), shown in the interface language. Anything else is shown as stored.
    static func settingsErrorTitle(_ text: String) -> String {
        if text == "No API provider is configured. Add one in Settings." {
            return String(localized: "No API provider is configured. Add one in Settings.")
        }
        let noModel = "No model selected. Pick a model at the top of the window or set a default model for "
        let inSettings = " in Settings."
        if text.hasPrefix(noModel), text.hasSuffix(inSettings), text.count > noModel.count + inSettings.count {
            let provider = String(text.dropFirst(noModel.count).dropLast(inSettings.count))
            return String(localized: "No model selected. Pick a model at the top of the window or set a default model for \(provider) in Settings.")
        }
        let invalid = "Invalid API base URL: "
        if text.hasPrefix(invalid) {
            let url = String(text.dropFirst(invalid.count))
            return String(localized: "Invalid API base URL: \(url)")
        }
        return text
    }

    /// "Keychain error (OSStatus -25300)." → -25300.
    static func keychainStatus(_ text: String) -> Int? {
        let prefix = "Keychain error (OSStatus ", suffix = ")."
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return nil }
        return Int(text.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Strata's own error texts (serve/server.py and the desktop app's shared port), whatever the
    /// status (the busy ones also arrive inside a started stream): they are specific enough to
    /// recognize without knowing the server.
    static func strataPresentation(_ message: String) -> ErrorPresentation? {
        if let overflow = ContextBudget.strataOverflow(fromError: message) {
            let context = TokenFormat.grouped(overflow.contextLength)
            if let maxTokens = overflow.maxTokens {
                let max = TokenFormat.grouped(maxTokens)
                let fits: String
                if let promptTokens = overflow.promptTokens {
                    let prompt = TokenFormat.grouped(promptTokens)
                    fits = String(localized: "The conversation (\(prompt) tokens) plus Max tokens (\(max)) is more than the context (\(context) tokens).")
                } else {
                    fits = String(localized: "The conversation plus Max tokens (\(max)) is more than the context (\(context) tokens).")
                }
                let fix: String
                if let room = overflow.room {
                    let room = TokenFormat.grouped(room)
                    fix = String(localized: "Lower Max tokens to at most \(room) in Conversation Settings (⌘I), or turn it off so Strata uses the room left.")
                } else {
                    fix = String(localized: "Lower Max tokens in Conversation Settings (⌘I), or turn it off so Strata uses the room left.")
                }
                return ErrorPresentation(
                    title: String(localized: "Max tokens does not fit in the model's context"),
                    detail: sentences(fits, fix))
            }
            let detail: String
            if let promptTokens = overflow.promptTokens {
                let prompt = TokenFormat.grouped(promptTokens)
                detail = String(localized: "The conversation is \(prompt) tokens; the model's context holds \(context). Start a new chat, fork from an earlier message, or roll back to drop recent messages. A larger context can only be set in Strata itself.")
            } else {
                detail = String(localized: "The model's context holds \(context). Start a new chat, fork from an earlier message, or roll back to drop recent messages. A larger context can only be set in Strata itself.")
            }
            return ErrorPresentation(
                title: String(localized: "The conversation no longer fits in the model's context"),
                detail: detail)
        }
        if isStrataVisionRefusal(message) {
            return ErrorPresentation(
                title: String(localized: "This Strata model does not read images"),
                detail: String(localized: "Picture reading is off for it. Turn on Pictures for the model in the Strata app (or run Strata's setup again and choose vision). Every message sends earlier images again: to go on without them, fork from a message before the first image."))
        }
        // The cases match Strata's English texts exactly: never translate them.
        switch message {
        case "This model is not ready.":
            return ErrorPresentation(title: String(localized: "The model is still loading in Strata"),
                                     detail: String(localized: "Retry once Strata shows it as ready."))
        case "No model is loaded.":
            return ErrorPresentation(title: String(localized: "No model is loaded in Strata"),
                                     detail: String(localized: "Load a model in the Strata app, then retry."))
        case "Choose a loaded model ID.", "That model ID is not loaded. Choose one from /v1/models.",
             "Use a model ID from /v1/models.", "This alias matches more than one instance. Choose its exact model ID.":
            return ErrorPresentation(title: String(localized: "Strata has no loaded model with this ID"),
                                     detail: String(localized: "Choose a model from the list (Refresh Model List in the model menu), or load one in the Strata app. Strata said: \(message)"))
        // Busy: Strata reads one request at a time, and its shared port drops Retry-After.
        case "the inference queue wait deadline expired; retry later", "the inference admission limit is full; retry later":
            return ErrorPresentation(title: String(localized: "Strata is busy with other requests"),
                                     detail: String(localized: "It answers one request at a time and this one waited too long. Retry when the other replies are done."))
        case "this instance is draining; retry against the next instance":
            return ErrorPresentation(title: String(localized: "Strata is shutting this model down"),
                                     detail: String(localized: "It finishes running replies and takes no new ones. Retry in a moment."))
        default:
            break
        }
        if message.hasPrefix("the GPU is in use by another program") {
            return ErrorPresentation(title: String(localized: "Another program is using the GPU memory"),
                                     detail: String(localized: "Strata keeps the model unloaded until enough VRAM is free. Close the other program (a game, another model), then retry. Strata said: \(message)"))
        }
        if message.hasPrefix("the engine's batch slots are not free") {
            return ErrorPresentation(title: String(localized: "Strata is busy with other requests"),
                                     detail: String(localized: "All of its parallel slots are in use. Retry in a moment."))
        }
        if message.hasSuffix("; the next request restarts it") {
            return ErrorPresentation(title: String(localized: "Strata's engine stopped"),
                                     detail: String(localized: "Retry to start it again (loading the model takes a while). Strata said: \(message)"))
        }
        if message.hasPrefix("New API requests are paused") {
            return ErrorPresentation(title: String(localized: "Strata has paused new requests"),
                                     detail: String(localized: "Resume them on Strata's Serving page, then retry."))
        }
        if message.contains("the engine is starting") {
            return ErrorPresentation(title: String(localized: "Strata is starting the model"),
                                     detail: String(localized: "This takes a minute or two. Retry shortly."))
        }
        return nil
    }

    // MARK: Cloudflare, redirects, broken streams

    /// Cloudflare's own errors (any server behind Cloudflare; the wording names Strata when the
    /// server is known to be Strata). The stored line is in `raw` (Details).
    static func cloudflarePresentation(_ error: CloudflareError, server: String, isStrata: Bool) -> ErrorPresentation {
        let name = isStrata ? "Strata" : server
        let Name = name.prefix(1).uppercased() + name.dropFirst()
        let direct = isStrata ? String(localized: "Strata's Tailscale or LAN address") : String(localized: "a direct address (Tailscale, LAN)")
        switch error.kind {
        case .timeout:
            return ErrorPresentation(
                title: String(localized: "No answer within Cloudflare's 100-second limit"),
                detail: String(localized: "\(Name) didn't start answering within 100 seconds (the model may be loading, or busy with another request). Try again in a minute; \(direct) has no such limit."))
        case .tunnelDown:
            let target = isStrata ? String(localized: "Strata's computer") : name
            return ErrorPresentation(
                title: String(localized: "The Cloudflare Tunnel is not connected to \(target)"),
                detail: isStrata
                    ? String(localized: "cloudflared or the Strata app isn't running on Strata's computer, or that computer is asleep or offline. Start them, then retry.")
                    : String(localized: "cloudflared isn't running on the server's computer, or that computer is asleep or offline. Start it, then retry."))
        case .originUnreachable:
            let why: String
            switch error.code ?? error.status {
            case 521: why = String(localized: "it refused the connection")
            case 522: why = String(localized: "the connection timed out")
            case 523: why = String(localized: "it is unreachable")
            case 520: why = String(localized: "it gave an answer Cloudflare could not read")
            case 504: why = String(localized: "it took too long")
            default: why = String(localized: "no usable answer came back")
            }
            return ErrorPresentation(
                title: String(localized: "Cloudflare can't reach \(name)"),
                detail: isStrata
                    ? String(localized: "Cloudflare is up, but Strata behind it didn't answer (\(why)). Check that the Strata app is running with network sharing on and that the tunnel points at its port, then retry.")
                    : String(localized: "Cloudflare is up, but \(name) behind it didn't answer (\(why)). Check that it is running and that the tunnel or DNS record points at it, then retry."))
        case .originTLS:
            return ErrorPresentation(
                title: String(localized: "Cloudflare could not open a secure connection to \(name)"),
                detail: String(localized: "This is set up on the Cloudflare side (SSL/TLS mode or the origin certificate), not in Parley."))
        case .challenge:
            return ErrorPresentation(
                title: String(localized: "Cloudflare's bot protection blocks Parley"),
                detail: String(localized: "This address answers apps with a browser check or a firewall block (WAF, Bot Fight Mode or Under Attack mode), which an API client can't pass. Add a Cloudflare rule that skips these checks for the API path (/v1/*), or use \(direct)."))
        case .rateLimited:
            return ErrorPresentation(
                title: String(localized: "Cloudflare is rate limiting this address"),
                detail: String(localized: "A rate-limiting rule on the Cloudflare side refused the request. Wait a minute, then retry."))
        case .access:
            return ErrorPresentation(
                title: String(localized: "This address is protected by Cloudflare Access"),
                detail: String(localized: "Access wants a sign-in in a browser, which Parley can't do (it never follows redirects, so nothing was sent to the sign-in page). Use \(direct), or a hostname without an Access policy that requires sign-in."),
                suggestsSettings: true)
        case .other:
            // A String, not an Int: String(localized:) would group the digits ("1,020").
            let code = String(error.code ?? error.status)
            return ErrorPresentation(
                title: error.title.map { String(localized: "Cloudflare error \(code): \($0)") }
                    ?? String(localized: "Cloudflare error \(code)"),
                detail: String(localized: "Cloudflare answered instead of \(name). Retry in a moment."))
        }
    }

    /// A 3xx: Parley never follows redirects (one could send the whole conversation elsewhere).
    static func redirectPresentation(status: Int, body: String, server: String, baseURL: String?, raw: String) -> ErrorPresentation {
        let Server = server.prefix(1).uppercased() + server.dropFirst()
        let base = baseURL.flatMap { URLComponents(string: $0) }
        if let target = ResponseText.redirectTarget(body), let base, base.scheme?.lowercased() == "http",
           target.scheme?.lowercased() == "https", target.host?.lowercased() == base.host?.lowercased() {
            var https = base
            https.scheme = "https"
            if base.port != nil { https.port = target.port }
            let address = https.string ?? "https://…"
            return ErrorPresentation(
                title: String(localized: "\(Server) only answers over https"),
                detail: String(localized: "Change the base URL to \(address) in Settings. Parley does not follow redirects, so nothing was sent to the new address."),
                status: "HTTP \(status)", raw: raw, suggestsSettings: true)
        }
        let target = ResponseText.redirectTarget(body)
        return ErrorPresentation(
            title: target?.host.map { String(localized: "\(Server) redirected the request to \($0)") }
                ?? String(localized: "\(Server) redirected the request"),
            detail: String(localized: "Parley does not follow redirects, so nothing was sent there. If that is the right address, put it in Settings as the base URL."),
            status: "HTTP \(status)", raw: raw, suggestsSettings: true)
    }

    /// The server had started answering when the connection broke.
    static func interruptedPresentation(_ interruption: (viaCloudflare: Bool, underlying: String?), server: String,
                                        isStrata: Bool, partialReply: Bool, raw: String) -> ErrorPresentation {
        let name = isStrata ? "Strata" : server
        let Name = name.prefix(1).uppercased() + name.dropFirst()
        let kept = partialReply ? String(localized: "The text received so far is kept.") : nil
        // Hosted APIs sit behind Cloudflare too: the tunnel wording is for Strata only.
        let cause = interruption.viaCloudflare
            ? (isStrata
               ? String(localized: "Cloudflare dropped the connection mid-reply: the tunnel may have restarted, or Strata's computer went to sleep or offline.")
               : String(localized: "The connection through Cloudflare closed mid-reply: the server or the network went away."))
            : String(localized: "\(Name) stopped answering mid-reply, or the network changed (sleep, Wi-Fi, VPN).")
        return ErrorPresentation(
            title: String(localized: "The connection dropped before the reply finished"),
            detail: sentences(kept, cause, String(localized: "Retry asks for the whole reply again.")),
            raw: raw)
    }
    /// An HTML page in a stored error body, reduced to its title (older versions stored the page).
    static func sanitizedBody(_ body: String) -> String {
        ResponseText.isHTMLPage(body) ? ResponseText.htmlSummary(body) : body
    }

    /// The stored error text, safe to show in full (tooltip, Details): HTML reduced to a line.
    static func displayText(_ error: String) -> String {
        guard let (status, body) = splitHTTP(error.trimmingCharacters(in: .whitespacesAndNewlines)) else { return error }
        if let cloudflare = CloudflareError.parse(status: status, body: body) { return "HTTP \(status): \(cloudflare.summary)" }
        let clean = sanitizedBody(body)
        return clean == body ? error : "HTTP \(status): \(clean)"
    }

    /// Settings' Test Connection: Cloudflare's and redirect errors as their readable title.
    static func connectionTestText(_ error: String) -> String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (status, body) = splitHTTP(text) else { return text }
        if CloudflareError.parse(status: status, body: body) != nil || (300..<400).contains(status) {
            let p = make(text)
            let title = p.title
            return sentences(String(localized: "\(title)."), p.detail)
        }
        return displayText(text)
    }

    /// Strata (engine or shared port) refused a request with images: the model has no picture reader.
    static func isStrataVisionRefusal(_ text: String) -> Bool {
        text.contains("started without the vision encoder") || text.contains("started without pictures")
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
