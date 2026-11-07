import Foundation
import Testing
@testable import Parley
import ParleyCore

// A link in model text opens only after a click and a confirmation that shows its real address.
// No test here can start a browser: `openLink` is replaced before anything is confirmed.

private func url(_ address: String) -> URL {
    URL(string: address)!
}

private func rendered(_ markdown: String) -> [URL] {
    MarkdownParser.inline(markdown).runs.compactMap(\.link)
}

@Test func linksThatMayOpen() throws {
    for address in ["http://example.com/", "https://example.com/a?b=1#c", "HTTP://Example.COM/", "https://[::1]:8443/x",
                    "http://192.168.1.20:1234/v1", "https://8.8.8.8/", "https://[::ffff:8.8.8.8]/", "https://a.b1/",
                    "https://example.com/%2E%2E?q=%41", "https://docs.example@notes.example/view"] {
        let link = try #require(PendingLink(url(address)), "\(address)")
        #expect(link.url.absoluteString == address)
    }
}

@Test func linksThatNeverOpen() throws {
    for address in ["mailto:a@example.com?body=secret", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/",
                    "ssh://example.com/", "tel:+15551234", "foo/bar", "//evil.example/x", "https:evil.example", "https:///evil.example",
                    // A browser decodes these, and the host it reaches is not the one that reads.
                    "https://accounts.good.example%2Eevil%2Enet/?q=secret", "https://%65vil.example/", "https://good.example%2F.evil.example/",
                    // A browser takes these for IPv4 addresses: 010.010.010.010 is 8.8.8.8, not 10.10.10.10.
                    "http://010.010.010.010/", "http://0177.1.2.3/", "http://0x7f.1/", "http://134744072/", "http://10.1/", "http://1.2.3.0x/"] {
        #expect(PendingLink(url(address)) == nil, "\(address)")
    }
}

@Test func renderedTextHoldsNoRealLink() {
    for markdown in ["[docs](https://example.com/a)", "<https://example.com/a>", "https://example.com/a",
                     "[a][r]\n\n[r]: https://example.com/a", "[![i](https://img.example/x.png)](https://example.com/a)"] {
        let links = rendered(markdown)
        #expect(links.count == 1, "\(markdown)")
        #expect(links.allSatisfy { $0.scheme == "parley-link" }, "\(markdown)")
        #expect(links.compactMap { PendingLink($0)?.url.absoluteString } == ["https://example.com/a"], "\(markdown)")
    }
}

@Test func linksThatNeverOpenAreNotLinks() {
    for markdown in ["[a](mailto:a@example.com)", "[a](file:///etc/passwd)", "[a](javascript:alert(1))", "[a](foo/bar)", "[a](https:evil.example)",
                     "[a](https://%65vil.example/)", "[a](http://010.010.010.010/)", "[a](https://e\u{A0}.example/)"] {
        #expect(rendered(markdown).isEmpty, "\(markdown)")
        #expect(String(MarkdownParser.inline(markdown).characters) == "a", "\(markdown)")
    }
}

@Test func aModelCannotForgeAnInertLink() throws {
    func inert(_ address: String) -> String { "parley-link:" + Data(address.utf8).base64EncodedString() }
    // Wrapped once, it is just another link: the gate shows what is really inside.
    let wrapped = try #require(rendered("[a](\(inert("https://evil.example/x")))").first)
    #expect(PendingLink(wrapped)?.url.absoluteString == "https://evil.example/x")
    #expect(rendered("[a](\(inert("file:///etc/passwd")))").isEmpty)
    // Wrapped twice, only one layer comes off, and what is left is no web address.
    #expect(rendered("[a](\(inert(inert("https://evil.example/x"))))").isEmpty)
    #expect(rendered("[a](parley-link:not%20base64)").isEmpty)
}

@Test func theSheetShowsTheRealSite() throws {
    let spoof = try #require(PendingLink(url("https://docs.example@notes.example/view")))
    #expect(spoof.host == "notes.example")
    #expect(spoof.address == "https://docs.example@notes.example/view")

    let lookalike = try #require(rendered("[Apple](https://аррӏе.example/中文)").first.flatMap(PendingLink.init))
    #expect(lookalike.host == "xn--80ak6aa92e.example")
    #expect(lookalike.address == "https://xn--80ak6aa92e.example/%E4%B8%AD%E6%96%87")
    #expect(!lookalike.hasHiddenCharacters)
}

@Test func addressesEscapeWhatCouldMisleadTheReader() {
    #expect(ToolDisplay.address("https://example.com/a?b=~1") == "https://example.com/a?b=~1")
    #expect(ToolDisplay.address("a\u{202E}b") == "a\\u{202E}b", "right-to-left override")
    #expect(ToolDisplay.address("a\u{200B}b") == "a\\u{200B}b", "zero width space")
    #expect(ToolDisplay.address("a\u{E0041}b") == "a\\u{E0041}b", "tag character")
    #expect(ToolDisplay.address("a\u{5D0}b") == "a\\u{5D0}b", "Hebrew letter")
    #expect(ToolDisplay.address("a\u{627}b") == "a\\u{627}b", "Arabic letter")
    #expect(ToolDisplay.address("a\u{430}b") == "a\\u{430}b", "Cyrillic lookalike")
    #expect(ToolDisplay.address("a b\nc\td") == "a\\u{20}b\\u{A}c\\u{9}d")
}

@MainActor
@Suite struct LinkConfirmationFlow {
    /// A state whose links are recorded, never opened.
    private func withState(_ body: (AppState, () -> [URL]) throws -> Void) throws {
        let root = try makeTempRoot()
        let suiteName = defaultsSuiteName(in: root)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { removeDefaultsSuite(suiteName, defaults, root: root) }
        let state = AppState(settings: AppSettings(defaults: defaults))
        var opened: [URL] = []
        state.openLink = { opened.append($0) }
        try body(state) { opened }
    }

    @Test func aClickAsksAndOpensNothing() throws {
        try withState { state, opened in
            let link = try #require(rendered("[Official docs](https://notes.example/?q=secret)").first)
            #expect(state.requestOpen(link))
            #expect(state.pendingLink?.address == "https://notes.example/?q=secret")
            #expect(opened().isEmpty)
        }
    }

    @Test func confirmingOpensTheAddressShownOnce() throws {
        try withState { state, opened in
            let link = try #require(rendered("[Official docs](https://notes.example/?q=secret)").first)
            _ = state.requestOpen(link)
            state.confirmPendingLink()
            state.confirmPendingLink()
            #expect(opened().map(\.absoluteString) == ["https://notes.example/?q=secret"])
            #expect(state.pendingLink == nil)
        }
    }

    @Test func cancellingOpensNothing() throws {
        try withState { state, opened in
            let link = try #require(rendered("[a](https://example.com/)").first)
            _ = state.requestOpen(link)
            state.pendingLink = nil
            state.confirmPendingLink()
            #expect(opened().isEmpty)
        }
    }

    @Test func aRefusedLinkNeverAsks() throws {
        try withState { state, opened in
            #expect(!state.requestOpen(url("mailto:a@example.com")))
            #expect(!state.requestOpen(url("https:evil.example")))
            #expect(state.pendingLink == nil)
            #expect(opened().isEmpty)
        }
    }

    @Test func aLinkTheSystemHandsOverRawStillAsks() throws {
        try withState { state, opened in
            #expect(state.requestOpen(url("https://example.com/")))
            #expect(state.pendingLink != nil)
            #expect(opened().isEmpty)
        }
    }
}
