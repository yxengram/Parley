import Foundation
import Testing
@testable import Parley
import ParleyCore

// Pure view-model helpers: markdown block parsing and error presentation.

@Test func markdownListsBecomeListBlocks() {
    let blocks = MarkdownParser.parse("Intro\n\n- one\n- two\n  - nested\n1. first\n2) second\n- [x] done\n\nAfter")
    #expect(blocks.count == 3)
    #expect(blocks.first == .paragraph("Intro"))
    #expect(blocks.last == .paragraph("After"))
    guard case .list(let items) = blocks[1] else {
        Issue.record("expected a list block, got \(blocks[1])")
        return
    }
    #expect(items.map(\.text) == ["one", "two", "nested", "first", "second", "done"])
    #expect(items.map(\.marker) == ["•", "•", "◦", "1.", "2)", "☑"])
    #expect(items.map(\.indent) == [0, 0, 1, 0, 0, 0])
}

@Test func markdownRuleAndCodeAreNotLists() {
    let blocks = MarkdownParser.parse("---\n```\n- not a list\n```")
    #expect(blocks == [.rule, .code(language: "", code: "- not a list")])
}

@Test func markdownInlineCodeIsStyled() {
    let attributed = MarkdownParser.inline("吃 `小笼包` 吧")
    let codeRuns = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
    #expect(codeRuns.count == 1)
    #expect(codeRuns.allSatisfy { $0.backgroundColor != nil })
}

@Test func errorPresentationReadsServerJSON() {
    let p = ErrorPresentation.make(#"HTTP 503: {"error":"Model is loading. Try again in a few seconds."}"#)
    #expect(p.title == "Model is loading. Try again in a few seconds.")
    #expect(p.status == "HTTP 503")
    #expect(!p.suggestsSettings)

    let auth = ErrorPresentation.make(#"HTTP 401: {"error":{"message":"Invalid API key"}}"#, providerName: "OpenAI")
    #expect(auth.title == "The server rejected the API key")
    #expect(auth.detail == "Invalid API key")
    #expect(auth.suggestsSettings)

    let down = ErrorPresentation.make("Could not connect to the server.", providerName: "LM Studio", baseURL: "http://localhost:1234/v1")
    #expect(down.title == "Can't reach LM Studio at localhost")
    #expect(down.suggestsSettings)

    #expect(ErrorPresentation.make("Something odd").title == "Something odd")
}

@Test func providerURLWarnsWhenVersionPathMissing() {
    #expect(ProviderEditor.urlWarning("http://100.100.1.2:1234")
            == "No version path. Most servers expect it to end in /v1, e.g. http://100.100.1.2:1234/v1.")
    #expect(ProviderEditor.urlWarning("http://localhost:1234/") != nil)
    #expect(ProviderEditor.urlWarning("http://100.100.1.2:1234/v1") == nil)
    #expect(ProviderEditor.urlWarning("http://192.168.1.20:1234/api/v1") == nil)
}

@Test func missingV1ErrorOffersSettings() {
    let p = ErrorPresentation.make("API error: Unexpected endpoint or method. (GET /models) " + ChatClient.missingVersionPathHint)
    #expect(p.suggestsSettings)
    #expect(!ErrorPresentation.make("API error: something else").suggestsSettings)
}

@Test func footerShowsUsageAndSpeed() {
    let usage = TokenUsage(promptTokens: 1184, completionTokens: 236, totalTokens: 1420)
    let exact = GenerationStats(tokensPerSecond: 42.34, completionTokens: 236, timeToFirstToken: 0.214, isEstimated: false)
    #expect(MessageRow.footerText(usage: usage, stats: exact)
            == "1184 prompt · 236 completion · 1420 total tokens · 42.3 tok/s · 0.21 s to first token")
    let estimated = GenerationStats(tokensPerSecond: 130.6, completionTokens: 90, isEstimated: true)
    #expect(MessageRow.footerText(usage: nil, stats: estimated) == "≈90 tokens · ≈131 tok/s")
    #expect(MessageRow.footerText(usage: nil, stats: nil) == nil)
    #expect(MessageRow.footerText(usage: usage, stats: nil) == "1184 prompt · 236 completion · 1420 total tokens")
}

@Test func tokenFormatting() {
    // One unit (k = 1024) for counts and limits alike.
    #expect(TokenFormat.tokens(950) == "950")
    #expect(TokenFormat.tokens(12_431) == "12.1k")
    #expect(TokenFormat.tokens(8_100) == "7.9k")
    #expect(TokenFormat.tokens(8_192) == "8k")
    #expect(TokenFormat.tokens(32_768) == "32k")
    #expect(TokenFormat.tokens(32_500) == "31.7k")
    #expect(TokenFormat.tokens(262_144) == "256k")
    #expect(TokenFormat.tokens(1_048_576) == "1M")
    #expect(TokenFormat.tokens(8_190) == TokenFormat.tokens(8_192))   // never reads as over the limit
    #expect(TokenFormat.parse("32768") == 32768)
    #expect(TokenFormat.parse(" 32,768 ") == 32768)
    #expect(TokenFormat.parse("32 768") == 32768)
    #expect(TokenFormat.parse("") == nil)
    #expect(TokenFormat.parse("0") == nil)
    #expect(TokenFormat.parse("32k") == nil)
    #expect(TokenFormat.parse("-5") == nil)
    #expect(TokenFormat.percent(39.4) == "39%")
    #expect(TokenFormat.percent(0.42) == "0.4%")
    #expect(TokenFormat.rate(9.96) == "10.0")
    #expect(TokenFormat.rate(123.4) == "123")
}

// MARK: - Strata

@Test func strataErrorsReadAsNextSteps() {
    // serve/server.py ContextOverflow, as ParleyError.http stores it.
    let tooLong = #"HTTP 400: {"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (40123 tokens) leaves no room to answer in the context (32768); requests are never truncated"}}"#
    let p = ErrorPresentation.make(tooLong, providerName: "Strata")
    #expect(p.title == "The conversation no longer fits in the model's context")
    #expect(p.detail?.contains("40,123") == true || p.detail?.contains("40123") == true)
    #expect(p.detail?.contains("fork from an earlier message") == true)
    #expect(p.status == "HTTP 400" && p.raw == tooLong)

    let fitOff = #"HTTP 400: {"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (30000 tokens) + max tokens (8192) exceeds the context (32768); requests are never truncated. Send a smaller max_tokens (at most 2760 here), or add \"fit_max_tokens\": true to the model's strata-<model>.json to shorten it to the room left (#545)"}}"#
    let m = ErrorPresentation.make(fitOff)
    #expect(m.title == "Max tokens does not fit in the model's context")
    #expect(m.detail?.contains("Lower Max tokens to at most") == true)

    let vision = ErrorPresentation.make(#"HTTP 400: {"error":{"type":"invalid_request_error","message":"this server was started without the vision encoder (run setup again and choose 'vision'), so it cannot read images"}}"#)
    #expect(vision.title == "This Strata model does not read images")
    #expect(vision.detail?.contains("fork from a message before the first image") == true)

    // The shared port's own answers ({"error":"…"} or the gateway's {"error":{"message":…}}).
    #expect(ErrorPresentation.make(#"HTTP 400: {"error":{"message":"This model is not ready.","type":"invalid_request_error","param":"model","code":null}}"#).title
            == "The model is still loading in Strata")
    #expect(ErrorPresentation.make(#"HTTP 409: {"error":"No model is loaded."}"#).title == "No model is loaded in Strata")
    #expect(ErrorPresentation.make(#"HTTP 400: {"error":{"message":"Choose a loaded model ID.","type":"invalid_request_error"}}"#).title
            == "Strata has no loaded model with this ID")
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":"New API requests are paused."}"#).title == "Strata has paused new requests")
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":{"type":"server_error","message":"the engine is starting (a minute or two); try again shortly"}}"#).title
            == "Strata is starting the model")
    #expect(ErrorPresentation.make(#"HTTP 502: {"error":{"message":"fetch failed","type":"server_error"}}"#, serverKind: .strata).title == "Strata's engine did not answer")
    // Any Node-based proxy says "fetch failed": only with the server known to be Strata.
    #expect(ErrorPresentation.make(#"HTTP 502: {"error":{"message":"fetch failed","type":"server_error"}}"#).title == "fetch failed")
    // Busy (serve/server.py, verbatim); the queue timeout can also arrive mid-stream.
    #expect(ErrorPresentation.make(#"HTTP 429: {"error":{"type":"rate_limit_error","code":"queue_wait_timeout","message":"the inference queue wait deadline expired; retry later"}}"#).title
            == "Strata is busy with other requests")
    #expect(ErrorPresentation.make("API error: the inference queue wait deadline expired; retry later").title == "Strata is busy with other requests")
    #expect(ErrorPresentation.make(#"HTTP 429: {"error":{"type":"rate_limit_error","code":"admission_full","message":"the inference admission limit is full; retry later"}}"#).title
            == "Strata is busy with other requests")
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":{"type":"server_error","code":"server_draining","message":"this instance is draining; retry against the next instance"}}"#).title
            == "Strata is shutting this model down")
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":{"type":"server_error","message":"the GPU is in use by another program: 1200 MiB of VRAM free, the model needs 20000 (min_free_vram_mib) - it stays unloaded until that is free"}}"#).title
            == "Another program is using the GPU memory")
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":{"type":"server_error","message":"the engine exited (code 3); the next request restarts it"}}"#).title
            == "Strata's engine stopped")
    // A plain 429 elsewhere keeps its generic reading.
    #expect(ErrorPresentation.make(#"HTTP 429: {"error":{"message":"Rate limit reached"}}"#).title == "Too many requests")
    // Mid-stream errors (data: {"error":…} after a 200) are "API error: …".
    #expect(ErrorPresentation.make("API error: the engine is starting (a minute or two); try again shortly").title == "Strata is starting the model")

    // Only with the server known to be Strata: the bare 500, the key hint, the port hint.
    let bare = ErrorPresentation.make("HTTP 500: Request failed", serverKind: .strata)
    #expect(bare.title == "Strata could not read the request" && bare.detail?.contains("12 MB") == true)
    #expect(ErrorPresentation.make("HTTP 500: Request failed").title == "Request failed")
    #expect(ErrorPresentation.make(#"HTTP 401: {"error":"Invalid API key"}"#, providerName: "Strata", serverKind: .strata).detail?.contains("sk-strata") == true)
    let down = ErrorPresentation.make("Could not connect to the server.", providerName: "Strata", baseURL: "http://100.64.0.9:47832/v1", serverKind: .strata)
    #expect(down.title == "Can't reach Strata at 100.64.0.9" && down.detail?.contains("another port") == true)
    // Other servers' texts are untouched.
    #expect(ErrorPresentation.make(#"HTTP 503: {"error":"Model is loading. Try again in a few seconds."}"#).title == "Model is loading. Try again in a few seconds.")
}

@Test func finishReasonNotes() {
    var thinking = Message(role: .assistant, content: "", reasoning: "Let me think",
                           stats: GenerationStats(completionTokens: 512, finishReason: "length"))
    // The cap was reached: raising it helps.
    #expect(MessageRow.finishNote(thinking, maxTokens: 512)?.hasPrefix("The reply ran out of tokens while thinking. Raise Max tokens") == true)
    // No cap sent, or fewer tokens than the cap (Strata shortened it to the room left): the context is full.
    for cap in [nil, 4096] {
        let note = MessageRow.finishNote(thinking, maxTokens: cap) ?? ""
        #expect(note.hasPrefix("The reply ran out of room in the context while thinking") && !note.contains("Raise Max tokens"))
    }
    // The server's count wins over the chunk count.
    thinking.usage = TokenUsage(promptTokens: 100, completionTokens: 4096)
    #expect(MessageRow.finishNote(thinking, maxTokens: 4096)?.contains("Raise Max tokens") == true)
    thinking.usage = nil
    // An estimated count under the cap proves nothing: the cap wording.
    thinking.stats?.isEstimated = true
    #expect(MessageRow.finishNote(thinking, maxTokens: 4096)?.contains("Raise Max tokens") == true)
    thinking.stats?.isEstimated = nil
    thinking.content = "Partial answer"
    #expect(MessageRow.finishNote(thinking, maxTokens: 512) == "The reply was cut off at the token limit (Max tokens).")
    #expect(MessageRow.finishNote(thinking)?.hasPrefix("The reply was cut off at the end of the context") == true)
    thinking.stats?.finishReason = "stop"
    #expect(MessageRow.finishNote(thinking) == nil)
    #expect(MessageRow.finishNote(Message(role: .assistant, content: "x")) == nil)
}

// Refused before sending (Strata's shared port takes 12 MiB): a short title, and no Retry.
@Test func tooLargeRequestReadsShortAndCannotBeRetried() {
    let stored = "API error: This request is 14.2 MB, more than the 12.0 MB the server accepts. Images are sent again with every message: remove some, or fork from a message before the first image."
    let p = ErrorPresentation.make(stored, providerName: "Strata", serverKind: .strata)
    #expect(p.title == "Request too large for Strata (14.2 MB of 12.0 MB)")
    #expect(p.detail?.contains("Fork from a message before the first image") == true)
    #expect(!p.retryable)
    // Text appended to an API error (the base URL hint) does not hide it.
    #expect(ChatClient.requestTooLarge(in: String(stored.dropFirst("API error: ".count)) + " " + ChatClient.missingVersionPathHint)?.limit == "12.0 MB")
    #expect(ErrorPresentation.make("HTTP 500: Request failed").retryable)
    #expect(ErrorPresentation.make("API error: the engine is starting (a minute or two); try again shortly").retryable)
}

// A model known not to read images: the warning covers images already in the conversation
// (every request sends them again), not only the draft.
@Test func imageWarningCoversTheHistory() {
    let info = ModelContextInfo(model: "qwen", serverKind: .strata, acceptsImages: false)
    let image = ParleyCore.Attachment(kind: .image, filename: "a.png", mimeType: "image/png", data: Data([0x89, 0x50]))
    let plain = [Message(role: .user, content: "hi"), Message(role: .assistant, content: "hello")]
    let withImage = [Message(role: .user, content: "look", attachments: [image]), Message(role: .assistant, content: "", error: "HTTP 400")]
    func warning(_ history: [Message], draft: [ParleyCore.Attachment]) -> String? {
        ComposerView.serverWarning(info: info, providerName: "Strata", model: "qwen", history: history, draft: draft, draftText: "")
    }
    #expect(warning(plain, draft: []) == nil)
    #expect(warning(plain, draft: [image])?.contains("Remove the image") == true)
    for draft: [ParleyCore.Attachment] in [[], [image]] {
        let text = warning(withImage, draft: draft) ?? ""
        #expect(text.contains("earlier images again") && text.contains("fork from a message before the first image") && !text.contains("Remove the image"))
    }
    // Unknown or able: no warning.
    var able = info
    able.acceptsImages = nil
    #expect(ComposerView.serverWarning(info: able, providerName: "Strata", model: "qwen", history: withImage, draft: [image], draftText: "") == nil)
}

@Test func readingPromptIsSpokenToo() {
    var snap = ContextSnapshot(usage: ContextUsage(tokens: 21, isEstimated: true), limit: nil, info: nil, manual: nil,
                               isProbing: false, tokensPerSecond: nil, speedIsEstimated: false, timeToFirstToken: nil,
                               isStreaming: true, reload: nil)
    #expect(ContextStatusBar.accessibilityText(snap) == "Context about 21 tokens, limit unknown")
    snap.promptProgress = PromptProgress(total: 40960, cached: 30000, processed: 36028)
    #expect(ContextStatusBar.accessibilityText(snap)
            .hasPrefix("Reading prompt 55 percent of \(TokenFormat.grouped(40960)) tokens, \(TokenFormat.grouped(30000)) cached. Context"))
    snap.isStreaming = false
    #expect(!ContextStatusBar.accessibilityText(snap).contains("Reading prompt"))
}

@Test func waitingTextShowsProgressOrElapsedTime() {
    #expect(WaitingIndicator.statusText(progress: nil, elapsed: 0.5) == "Waiting for response…")
    #expect(WaitingIndicator.statusText(progress: nil, elapsed: 12.4) == "Waiting for response… 12 s")
    let progress = PromptProgress(total: 40960, cached: 30000, processed: 35480)
    let text = WaitingIndicator.statusText(progress: progress, elapsed: 7)
    #expect(text.hasPrefix("Reading the prompt: 50% of ") && text.hasSuffix("cached) · 7 s"))
    #expect(!WaitingIndicator.statusText(progress: PromptProgress(total: 100, processed: 10), elapsed: 1).contains("cached"))
}

@Test func strataPromptStatsInThePopover() {
    var snap = ContextSnapshot(usage: ContextUsage(tokens: 0, isEstimated: false), limit: nil, info: nil, manual: nil,
                               isProbing: false, tokensPerSecond: nil, speedIsEstimated: false, timeToFirstToken: nil,
                               isStreaming: false, reload: nil)
    #expect(ContextPopover.promptText(snap) == nil)
    snap.promptTokensRead = 1204
    snap.promptTokensPerSecond = 849.9
    snap.cachedPromptTokens = 30112
    let text = ContextPopover.promptText(snap) ?? ""
    #expect(text.contains("read at 850 tok/s") && text.hasSuffix("cached"))
}

// MARK: - Cloudflare, redirects, broken streams

@Test func cloudflareErrorsReadAsNextSteps() {
    let timeout = ErrorPresentation.make("HTTP 524: Cloudflare error 524: A timeout occurred · Ray ID a54c823f3e275e92-BNE",
                                         providerName: "Strata (Cloudflare)", serverKind: .strata)
    #expect(timeout.title == "No answer within Cloudflare's 100-second limit")
    #expect(timeout.detail == "Strata didn't start answering within 100 seconds (the model may be loading, or busy with another request). Try again in a minute; Strata's Tailscale or LAN address has no such limit.")
    #expect(timeout.status == "HTTP 524" && timeout.retryable)
    #expect(timeout.raw == "HTTP 524: Cloudflare error 524: A timeout occurred · Ray ID a54c823f3e275e92-BNE")
    // Any server behind Cloudflare, without Strata in the wording.
    let generic = ErrorPresentation.make("HTTP 524: Cloudflare error 524: A timeout occurred", providerName: "My API")
    #expect(generic.detail?.hasPrefix("My API didn't start answering") == true && generic.detail?.contains("Strata") == false)

    let tunnel = ErrorPresentation.make("HTTP 530: Cloudflare error 1033: Cloudflare Tunnel error", serverKind: .strata)
    #expect(tunnel.title == "The Cloudflare Tunnel is not connected to Strata's computer")
    #expect(tunnel.detail?.contains("cloudflared or the Strata app isn't running") == true)
    #expect(ErrorPresentation.make("HTTP 530: Cloudflare error 1033").title == "The Cloudflare Tunnel is not connected to the server")

    let access = ErrorPresentation.make("HTTP 302: Cloudflare Access sign-in at team.cloudflareaccess.com (redirect not followed)")
    #expect(access.title == "This address is protected by Cloudflare Access" && access.suggestsSettings)
    let challenge = ErrorPresentation.make("HTTP 403: Cloudflare challenge: Just a moment...", providerName: "Strata")
    #expect(challenge.title == "Cloudflare's bot protection blocks Parley" && !challenge.suggestsSettings)
    #expect(ErrorPresentation.make("HTTP 403: Cloudflare error 1020: Access denied").title == "Cloudflare's bot protection blocks Parley")
    #expect(ErrorPresentation.make("HTTP 429: Cloudflare error 1015").title == "Cloudflare is rate limiting this address")
    #expect(ErrorPresentation.make("HTTP 521: Cloudflare error 521: Web server is down", serverKind: .strata).title == "Cloudflare can't reach Strata")
    #expect(ErrorPresentation.make("HTTP 502: Cloudflare error 502: Bad gateway", providerName: "Strata").detail?.contains("didn't answer") == true)
    #expect(ErrorPresentation.make("HTTP 526: Cloudflare error 526: Invalid SSL certificate").title.hasPrefix("Cloudflare could not open a secure connection"))

    // Strata's own errors through the tunnel keep their reading (a 401 is still about the key).
    #expect(ErrorPresentation.make(#"HTTP 401: {"error":"Invalid API key"}"#, serverKind: .strata).title == "The server rejected the API key")
}

// Conversations saved before Parley knew Cloudflare hold the raw page: never shown as markup.
@Test func storedHTMLPagesAreNeverShown() {
    let style = String(repeating: ".cf{margin:0}", count: 300)
    let page = "<!DOCTYPE html><html><head><title>strata.example.net | 524: A timeout occurred</title><link href=\"/cdn-cgi/styles/main.css\"><style>\(style)</style></head><body>"
    let old = "HTTP 524: " + String(page.prefix(1990))
    let p = ErrorPresentation.make(old, serverKind: .strata)
    #expect(p.title == "No answer within Cloudflare's 100-second limit")
    #expect(p.raw?.contains("<") == false)
    #expect(ErrorPresentation.displayText(old) == "HTTP 524: Cloudflare error 524: A timeout occurred")

    let nginx = "HTTP 502: <html><head><title>502 Bad Gateway</title></head><body><h1>502 Bad Gateway</h1></body></html>"
    let n = ErrorPresentation.make(nginx)
    #expect(n.title == "502 Bad Gateway" && n.raw == "HTTP 502: 502 Bad Gateway")
    #expect(ErrorPresentation.displayText(nginx) == "HTTP 502: 502 Bad Gateway")
    #expect(ErrorPresentation.displayText("HTTP 400: plain") == "HTTP 400: plain")
}

@Test func redirectsSayWhereToGo() {
    let https = ErrorPresentation.make("HTTP 301: Redirect to https://strata.example.net/v1/models (not followed)",
                                       providerName: "Strata", baseURL: "http://strata.example.net/v1")
    #expect(https.title == "Strata only answers over https")
    #expect(https.detail?.contains("https://strata.example.net/v1") == true && https.suggestsSettings)
    let elsewhere = ErrorPresentation.make("HTTP 307: Redirect to http://other.example/v1 (not followed)", providerName: "Proxy",
                                           baseURL: "http://192.168.1.2:8080/v1")
    #expect(elsewhere.title == "Proxy redirected the request to other.example")
    #expect(ErrorPresentation.connectionTestText("HTTP 530: Cloudflare error 1033").hasPrefix("The Cloudflare Tunnel is not connected"))
    #expect(ErrorPresentation.connectionTestText(#"HTTP 401: {"error":"Invalid API key"}"#) == #"HTTP 401: {"error":"Invalid API key"}"#)
}

@Test func interruptedRepliesKeepTheirText() {
    let viaCloudflare = "API error: The connection closed before the reply finished (through Cloudflare): The network connection was lost."
    let p = ErrorPresentation.make(viaCloudflare, providerName: "Strata (Cloudflare)", serverKind: .strata, partialReply: true)
    #expect(p.title == "The connection dropped before the reply finished")
    #expect(p.detail?.hasPrefix("The text received so far is kept. Cloudflare dropped the connection mid-reply") == true)
    #expect(p.raw == viaCloudflare && p.retryable && !p.suggestsSettings)
    let direct = ErrorPresentation.make("API error: The connection closed before the reply finished.", providerName: "LM Studio")
    #expect(direct.detail == "LM Studio stopped answering mid-reply, or the network changed (sleep, Wi-Fi, VPN). Retry asks for the whole reply again.")
    let openAI = ErrorPresentation.make("API error: The connection closed before the reply finished (through Cloudflare).", providerName: "OpenAI")
    #expect(openAI.detail?.contains("tunnel") == false && openAI.detail?.contains("through Cloudflare closed") == true)
    // A connection lost before any answer is still "can't reach".
    #expect(ErrorPresentation.make("The network connection was lost.", providerName: "LM Studio").title.hasPrefix("Can't reach"))
}

// A JSON error that quotes markup is the server's message, not an HTML page.
@Test func jsonErrorQuotingMarkupIsShownAsIs() {
    let stored = #"HTTP 400: {"error":{"message":"Invalid content: <title>x</title> in message"}}"#
    #expect(ErrorPresentation.displayText(stored) == stored)
    #expect(ErrorPresentation.sanitizedBody(#"{"error":"<body> is not allowed"}"#) == #"{"error":"<body> is not allowed"}"#)
    #expect(ErrorPresentation.make(stored, providerName: "Strata").title == "Invalid content: <title>x</title> in message")
}

@Test func plainHTTPOverTheInternetWarns() {
    let warning = ProviderEditor.urlWarning("http://strata.example.net/v1")
    #expect(warning?.contains("API key and chats travel unencrypted") == true)
    #expect(warning?.contains("https://strata.example.net/v1") == true)
    #expect(ProviderEditor.urlWarning("http://strata.example.net:8080/v1")?.contains("(https://strata.example.net/v1)") == true)
    // Tailscale (WireGuard), LAN, loopback and https stay quiet.
    #expect(ProviderEditor.urlWarning("http://100.101.102.103:47832/v1") == nil)
    #expect(ProviderEditor.urlWarning("http://192.168.1.20:1234/v1") == nil)
    #expect(ProviderEditor.urlWarning("http://localhost:1234/v1") == nil)
    #expect(ProviderEditor.urlWarning("https://strata.example.net/v1") == nil)
    // Tailscale MagicDNS names are in the tailnet too.
    #expect(ProviderEditor.urlWarning("http://mac.tailnet-1234.ts.net:47832/v1") == nil)
    #expect(ProviderEditor.urlWarning("http://MAC.tailnet-1234.TS.NET.:47832/v1") == nil)
    #expect(ProviderEditor.urlWarning("http://ts.net.example.com/v1") != nil)
    // The port hint is for local Strata addresses only.
    #expect(ErrorPresentation.make("A server with the specified hostname could not be found.", providerName: "Strata",
                                   baseURL: "https://strata.example.net/v1", serverKind: .strata).detail?.contains("another port") == false)
}

@Test func learnedLimitSaysWhereItCameFrom() {
    #expect(ContextPopover.sourceText(.learned, serverKind: .strata) == "learned from Strata's error")
    #expect(ContextPopover.sourceText(.learned) == "learned from the server's error")
    let info = ModelContextInfo(model: "m", maxContextLength: 262144)
    #expect(ContextBudget.limit(info: info, manual: nil, learned: 131072) == ContextLimit(tokens: 131072, source: .learned))
    #expect(ContextBudget.limit(info: info, manual: 65536, learned: 131072) == ContextLimit(tokens: 65536, source: .manual))
    #expect(ContextBudget.limit(info: ModelContextInfo(model: "m", loadedContextLength: 8192), manual: nil, learned: 131072)?.source == .server)
}
