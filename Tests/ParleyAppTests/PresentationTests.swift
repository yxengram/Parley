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
