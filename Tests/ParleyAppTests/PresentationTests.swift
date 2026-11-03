import Foundation
import Testing
@testable import Parley

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
