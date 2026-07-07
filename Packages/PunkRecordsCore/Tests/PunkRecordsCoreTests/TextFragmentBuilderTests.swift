import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("TextFragmentBuilder — scroll-to-text-fragment encoding")
struct TextFragmentBuilderTests {

    // MARK: - Percent-encoding

    @Test("Encodes spaces and leaves plain alphanumerics untouched")
    func encodesSpaces() {
        #expect(TextFragmentBuilder.percentEncode("hello world") == "hello%20world")
    }

    @Test("Encodes -, comma, and & — the text-fragment spec's reserved directive syntax")
    func encodesReservedDirectiveCharacters() {
        #expect(TextFragmentBuilder.percentEncode("a-b,c&d") == "a%2Db%2Cc%26d")
    }

    @Test("Leaves an unreserved character like '.' unencoded")
    func leavesPeriodUnencoded() {
        #expect(TextFragmentBuilder.percentEncode("U.S.A.") == "U.S.A.")
    }

    @Test("Percent-encodes accented and emoji unicode as UTF-8 bytes")
    func encodesUnicodeAndEmoji() {
        #expect(TextFragmentBuilder.percentEncode("café 😀") == "caf%C3%A9%20%F0%9F%98%80")
    }

    // MARK: - Unique match

    @Test("A unique substring resolves to a plain text= fragment")
    func uniqueMatch() {
        let page = "The quick brown fox jumps over the lazy dog."
        let outcome = TextFragmentBuilder.build(supportingText: "brown fox jumps", pageText: page)
        #expect(outcome == .unique(fragment: "text=brown%20fox%20jumps"))
    }

    @Test("Whitespace runs in the needle match any whitespace run in the page (e.g. a wrapped line)")
    func whitespaceNormalizedMatch() {
        let page = "The quick brown\nfox   jumps over the lazy dog."
        let outcome = TextFragmentBuilder.build(supportingText: "brown fox jumps", pageText: page)
        #expect(outcome == .unique(fragment: "text=brown%20fox%20jumps"))
    }

    @Test("Trims leading/trailing whitespace off the supporting text before matching")
    func trimsSupportingText() {
        let page = "The quick brown fox jumps over the lazy dog."
        let outcome = TextFragmentBuilder.build(supportingText: "  brown fox jumps  ", pageText: page)
        #expect(outcome == .unique(fragment: "text=brown%20fox%20jumps"))
    }

    // MARK: - No match

    @Test("A supporting text absent from the page resolves to notFound")
    func noMatch() {
        let page = "The quick brown fox jumps over the lazy dog."
        let outcome = TextFragmentBuilder.build(supportingText: "a purple elephant", pageText: page)
        #expect(outcome == .notFound)
    }

    @Test("An empty (or whitespace-only) supporting text resolves to notFound")
    func emptySupportingTextIsNotFound() {
        #expect(TextFragmentBuilder.build(supportingText: "   ", pageText: "some page text") == .notFound)
        #expect(TextFragmentBuilder.build(supportingText: "", pageText: "some page text") == .notFound)
    }

    @Test("An empty page resolves to notFound")
    func emptyPageIsNotFound() {
        #expect(TextFragmentBuilder.build(supportingText: "brown fox", pageText: "") == .notFound)
    }

    // MARK: - Disambiguation (non-unique match)

    @Test("A non-unique match is disambiguated with prefix/suffix context around the first occurrence")
    func disambiguatesNonUniqueMatch() {
        let page = "In the morning the brown fox ran fast. In the evening the brown fox slept well."
        let outcome = TextFragmentBuilder.build(supportingText: "brown fox", pageText: page)
        let expectedFragment = "text="
            + TextFragmentBuilder.percentEncode("the morning the") + "-,"
            + TextFragmentBuilder.percentEncode("brown fox") + ",-"
            + TextFragmentBuilder.percentEncode("ran fast. In")
        #expect(outcome == .disambiguated(fragment: expectedFragment))
    }

    @Test("Disambiguation gives up (ambiguous) when even the widest context window can't tell occurrences apart")
    func ambiguousWhenContextIsIdentical() {
        let padding = Array(repeating: "pad", count: 15).joined(separator: " ")
        let page = "\(padding) target phrase \(padding) target phrase \(padding)"
        let outcome = TextFragmentBuilder.build(supportingText: "target phrase", pageText: page)
        #expect(outcome == .ambiguous)
    }

    // MARK: - URL convenience wrapper

    @Test("url(pageURL:supportingText:pageText:) appends the resolved fragment to the page URL")
    func urlWrapperAppendsFragment() {
        let page = "The quick brown fox jumps over the lazy dog."
        let pageURL = URL(string: "https://example.com/article")!
        let url = TextFragmentBuilder.url(pageURL: pageURL, supportingText: "brown fox jumps", pageText: page)
        #expect(url?.absoluteString == "https://example.com/article#:~:text=brown%20fox%20jumps")
    }

    @Test("url(pageURL:supportingText:pageText:) replaces any existing fragment on the page URL")
    func urlWrapperReplacesExistingFragment() {
        let page = "The quick brown fox jumps over the lazy dog."
        let pageURL = URL(string: "https://example.com/article#section1")!
        let url = TextFragmentBuilder.url(pageURL: pageURL, supportingText: "brown fox jumps", pageText: page)
        #expect(url?.absoluteString == "https://example.com/article#:~:text=brown%20fox%20jumps")
    }

    @Test("url(pageURL:supportingText:pageText:) returns nil when the text can't be resolved")
    func urlWrapperReturnsNilForUnresolvedText() {
        let page = "The quick brown fox jumps over the lazy dog."
        let pageURL = URL(string: "https://example.com/article")!
        let url = TextFragmentBuilder.url(pageURL: pageURL, supportingText: "a purple elephant", pageText: page)
        #expect(url == nil)
    }

    // MARK: - findOccurrences (internal helper, exercised directly for clarity)

    @Test("findOccurrences counts overlapping-free repeated occurrences correctly")
    func findOccurrencesCountsRepeats() {
        let page = "cat cat cat"
        let occurrences = TextFragmentBuilder.findOccurrences(of: "cat", in: page)
        #expect(occurrences.count == 3)
    }
}
