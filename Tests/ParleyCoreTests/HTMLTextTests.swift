import Foundation
import Testing
@testable import ParleyCore

@Suite struct HTMLTextTests {
    @Test func theTitleComesFirst() {
        #expect(HTMLText.plain("<html><head><title> My  &amp; page\n</title></head><body><p>Hello</p></body></html>") == "My & page\n\nHello")
        #expect(HTMLText.plain("<title>Only</title>") == "Only")
        #expect(HTMLText.plain("<title>One</title><title>Two</title>x") == "One\n\nx")
        #expect(HTMLText.plain("<title></title>x") == "x")
    }

    @Test func whatIsNotTextGoes() {
        let html = """
        a<script>var x = "<p>no</p>";</script>b<style>p { color: red }</style>c<noscript>nope</noscript>d
        <template><p>no</p></template>e<svg><text>no</text></svg>f<!-- <p>no</p> -->g<!DOCTYPE html>h<?xml version="1.0"?>i
        """
        #expect(HTMLText.plain(html) == "abcd efghi")
    }

    @Test func aClosingTagMatchesInAnyCase() {
        #expect(HTMLText.plain("a<SCRIPT>x</ScRiPt >b") == "ab")
    }

    @Test func aLongerNameDoesNotCloseAnElement() {
        #expect(HTMLText.plain("<script>var a='</scripts>'; secretCode();</script>after") == "after")
        #expect(HTMLText.plain("<style>/*</style-x>*/ .hidden{color:red}</style>after") == "after")
        #expect(HTMLText.plain("<title>a</titles>b</title>x") == "a</titles>b\n\nx")
    }

    @Test func aClosingTagMayEndInSpaceOrSlash() {
        #expect(HTMLText.plain("a<script>x</script\n>b") == "ab")
        #expect(HTMLText.plain("a<script>x</script/>b") == "ab")
        #expect(HTMLText.plain("a<script>x</script") == "a")
    }

    @Test func aQuoteOpensAValueOnlyRightAfterTheEquals() {
        #expect(HTMLText.plain("<p class=o'brien>Hello</p><p>World</p>") == "Hello\n\nWorld")
        #expect(HTMLText.plain("<a title=it's>x</a><script>var s='a>secret code';</script>end") == "xend")
        #expect(HTMLText.plain("<a href=\"x\"\">text</a><p>more</p>") == "text\n\nmore")
        #expect(HTMLText.plain("<a href=x?a='b>Text</a><p>more</p>") == "Text\n\nmore")
        #expect(HTMLText.plain("<a it's>x</a>y") == "xy")
    }

    @Test func aQuotedValueStillHoldsAClosingBracket() {
        #expect(HTMLText.plain("<a title=\"1>2\">x</a>") == "x")
        #expect(HTMLText.plain("<a title = '1>2'>x</a>") == "x")
    }

    @Test func aSelfClosedSvgHidesNothing() {
        #expect(HTMLText.plain("<p>before</p><svg width=1/><p>all the rest</p>") == "before\n\nall the rest")
        #expect(HTMLText.plain("<svg/><p>one</p><svg><path/></svg><p>two</p>") == "one\n\ntwo")
        #expect(HTMLText.plain("<svg><text>no</text></svg>yes") == "yes")
    }

    /// HTML ignores `/>` on these.
    @Test func onlySvgClosesItself() {
        #expect(HTMLText.plain("<script src=x/>hidden</script>after") == "after")
        #expect(HTMLText.plain("<style/>hidden</style>after") == "after")
    }

    @Test func theShortCommentsAreComments() {
        #expect(HTMLText.plain("<!--><p>visible</p>") == "visible")
        #expect(HTMLText.plain("<!---><p>visible</p>") == "visible")
        #expect(HTMLText.plain("<!-- a --!><p>visible</p>") == "visible")
        #expect(HTMLText.plain("<!---->visible") == "visible")
    }

    @Test func aCommentStaysOpenWhereHTMLKeepsItOpen() {
        #expect(HTMLText.plain("<!--!><p>hidden</p>") == "")
        #expect(HTMLText.plain("<!---!><p>hidden</p>") == "")
        #expect(HTMLText.plain("<!--[if !IE]><!-->shown<!--<![endif]-->") == "shown")
    }

    @Test func blocksBreakLinesAndInlineTagsDoNot() {
        #expect(HTMLText.plain("<p>one</p><p>two</p>") == "one\n\ntwo")
        #expect(HTMLText.plain("one<br>two<br/>three") == "one\ntwo\nthree")
        #expect(HTMLText.plain("<ul><li>a</li><li>b</li></ul>after") == "a\nb\n\nafter")
        #expect(HTMLText.plain("<b>bo</b>ld <a href=\"x\">link</a>") == "bold link")
        #expect(HTMLText.plain("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>") == "a b\nc")
    }

    @Test func whitespaceCollapses() {
        #expect(HTMLText.plain("  a \n\t b\r\n\r\n c  ") == "a b c")
        #expect(HTMLText.plain("<div>  a  </div>  <div>  b  </div>") == "a\nb")
    }

    @Test func entitiesDecodeOnceAndStayText() {
        #expect(HTMLText.plain("a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;") == "a & b <c> \"d\" 'e'")
        #expect(HTMLText.plain("&#65;&#x42;&#X43;&#26085;&#x1F600;") == "ABC日😀")
        #expect(HTMLText.plain("&lt;script&gt;alert(1)&lt;/script&gt;") == "<script>alert(1)</script>")
        #expect(HTMLText.plain("&amp;lt;") == "&lt;")
        #expect(HTMLText.plain("a&nbsp;b &mdash; c&hellip;") == "a b \u{2014} c\u{2026}")
    }

    @Test func aBadEntityDoesNoHarm() {
        #expect(HTMLText.plain("&nosuch; & &; &#; &#x; AT&T") == "&nosuch; & &; &#; &#x; AT&T")
        #expect(HTMLText.plain("&#0;&#xD800;&#x110000;&#99999999999999;").unicodeScalars.allSatisfy { $0 == "\u{FFFD}" })
        #expect(HTMLText.plain("&#65") == "A")
        #expect(HTMLText.plain("&") == "&")
    }

    @Test func aLessThanSignIsText() {
        #expect(HTMLText.plain("1 < 2 and 3 <4") == "1 < 2 and 3 <4")
        #expect(HTMLText.plain("<") == "<")
    }

    @Test func quotesCanHoldTheEndOfATag() {
        #expect(HTMLText.plain(#"<a title="x > y">link</a>"#) == "link")
        #expect(HTMLText.plain("<a title='x > y'>link</a>") == "link")
    }

    @Test func anUnterminatedConstructEndsTheText() {
        #expect(HTMLText.plain("a<script>never closed") == "a")
        #expect(HTMLText.plain("a<!-- never closed") == "a")
        #expect(HTMLText.plain("a<div class=\"never") == "a")
        #expect(HTMLText.plain("a<div") == "a")
        #expect(HTMLText.plain("a<!doctype") == "a")
        #expect(HTMLText.plain("a<title>never closed") == "never closed\n\na")
        #expect(HTMLText.plain("a</") == "a</")
    }

    @Test func nonASCIIPassesThrough() {
        #expect(HTMLText.plain("<p>日本語 — café</p>") == "日本語 — café")
        #expect(HTMLText.plain("") == "")
    }

    /// Each of these is quadratic in a naive scanner. A generous bound, so a busy machine cannot fail
    /// it: at quadratic cost these inputs would take hours, not seconds.
    @Test(arguments: ["<", "<a ", "<!--", "&", "&#", "<script>", "</script", "<title>", "<a b='", "<div>", "-->"])
    func largeHostileInputStaysLinear(_ piece: String) {
        let html = String(repeating: piece, count: 300_000 / piece.utf8.count + 1)
        let start = Date()
        _ = HTMLText.plain(html)
        #expect(Date().timeIntervalSince(start) < 20)
    }
}
