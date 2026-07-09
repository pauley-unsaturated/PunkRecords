import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("ComposerURLDetector — the 'entire message is a lone URL' affordance rule")
struct ComposerURLDetectorTests {

    @Test("A bare https URL alone triggers")
    func bareHTTPSURL() {
        #expect(ComposerURLDetector.summarizableURL(in: "https://example.com/article") != nil)
    }

    @Test("A bare http URL alone triggers")
    func bareHTTPURL() {
        #expect(ComposerURLDetector.summarizableURL(in: "http://example.com") != nil)
    }

    @Test("Surrounding whitespace/newlines are trimmed")
    func trimsWhitespace() {
        let url = ComposerURLDetector.summarizableURL(in: "  \n https://example.com/page \n  ")
        #expect(url?.absoluteString == "https://example.com/page")
    }

    @Test("A URL with query string and fragment still counts as a single token")
    func urlWithQueryAndFragment() {
        let url = ComposerURLDetector.summarizableURL(in: "https://example.com/page?x=1&y=2#section")
        #expect(url?.absoluteString == "https://example.com/page?x=1&y=2#section")
    }

    @Test("A message that MENTIONS a URL among other words does not trigger")
    func urlAmongOtherWords() {
        #expect(ComposerURLDetector.summarizableURL(in: "check this out https://example.com, thoughts?") == nil)
    }

    @Test("A URL followed by trailing prose on another line does not trigger")
    func urlPlusTrailingLine() {
        #expect(ComposerURLDetector.summarizableURL(in: "https://example.com\nwhat do you think?") == nil)
    }

    @Test("Two URLs together do not trigger (not a LONE url)")
    func twoURLs() {
        #expect(ComposerURLDetector.summarizableURL(in: "https://example.com https://other.com") == nil)
    }

    @Test("Empty or whitespace-only text does not trigger")
    func emptyText() {
        #expect(ComposerURLDetector.summarizableURL(in: "") == nil)
        #expect(ComposerURLDetector.summarizableURL(in: "   \n\t  ") == nil)
    }

    @Test("Non-http(s) schemes are ignored")
    func nonHTTPScheme() {
        #expect(ComposerURLDetector.summarizableURL(in: "ftp://example.com/file") == nil)
        #expect(ComposerURLDetector.summarizableURL(in: "mailto:someone@example.com") == nil)
        #expect(ComposerURLDetector.summarizableURL(in: "file:///Users/me/note.md") == nil)
    }

    @Test("A URL with no host does not trigger")
    func noHost() {
        #expect(ComposerURLDetector.summarizableURL(in: "https://") == nil)
    }

    @Test("Plain non-URL text does not trigger")
    func plainText() {
        #expect(ComposerURLDetector.summarizableURL(in: "just a normal chat message") == nil)
    }

    // MARK: - Code fences

    @Test("A URL wrapped alone in a triple-backtick fence does not trigger")
    func urlInTripleBacktickFence() {
        #expect(ComposerURLDetector.summarizableURL(in: "```https://example.com```") == nil)
        #expect(ComposerURLDetector.summarizableURL(in: "```\nhttps://example.com\n```") == nil)
    }

    @Test("A URL wrapped alone in a single-backtick span does not trigger")
    func urlInSingleBacktickSpan() {
        #expect(ComposerURLDetector.summarizableURL(in: "`https://example.com`") == nil)
    }

    @Test("A lone URL alongside an UNRELATED fenced code block still triggers, since the fence strips to empty")
    func urlOutsideUnrelatedFence() {
        // The whole message minus the fenced content is just the URL.
        let url = ComposerURLDetector.summarizableURL(in: "https://example.com ``` ```")
        #expect(url?.absoluteString == "https://example.com")
    }
}
