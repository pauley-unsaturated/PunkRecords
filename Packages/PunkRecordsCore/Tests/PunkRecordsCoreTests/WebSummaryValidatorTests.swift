import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebSummaryValidator — structural validation of a decoded payload against its source page")
struct WebSummaryValidatorTests {

    private static func content(pageText: String, anchor: String = "intro") -> WebContent {
        WebContent(
            title: "Test Article",
            byline: nil,
            contentMarkdown: pageText,
            headings: [WebHeading(level: 1, text: "Intro", anchorID: anchor)],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: URL(string: "https://example.com/article")!,
            canonicalURL: nil
        )
    }

    private static func citation(_ text: String) -> WebSummaryCitation {
        WebSummaryCitation(citationIndex: 1, supportingText: text, nearestHeadingAnchor: "intro")
    }

    /// A structurally valid payload: 5 key points, 2 quotes, all citations
    /// grounded in `pageText`.
    private static func validPayload(pageText: String, sentences: [String]) -> WebSummaryPayload {
        WebSummaryPayload(
            tldr: "A faithful summary.",
            keyPoints: sentences.prefix(5).map { WebSummaryKeyPoint(text: "Point about \($0.prefix(5))", citation: citation($0)) },
            quotes: sentences.suffix(2).map { WebSummaryQuote(citation: citation($0)) },
            whyItMatters: ["An open question."]
        )
    }

    private static let sentences = [
        "Alpha sentence one is here.",
        "Beta sentence two is here.",
        "Gamma sentence three is here.",
        "Delta sentence four is here.",
        "Epsilon sentence five is here.",
        "Zeta sentence six is here.",
        "Eta sentence seven is here."
    ]

    private static let pageText = sentences.joined(separator: " ")

    // MARK: - Passing fixture

    @Test("A well-formed, fully-grounded payload validates cleanly")
    func passingFixture() {
        let content = Self.content(pageText: Self.pageText)
        let payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.isEmpty)
        #expect(WebSummaryValidator.isValid(payload: payload, content: content))
    }

    // MARK: - Failing fixtures

    @Test("Flags a blank TL;DR")
    func failsOnMissingTLDR() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        payload = WebSummaryPayload(tldr: "   ", keyPoints: payload.keyPoints, quotes: payload.quotes, whyItMatters: payload.whyItMatters)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.missingTLDR))
    }

    @Test("Flags too few key points")
    func failsOnTooFewKeyPoints() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        payload = WebSummaryPayload(
            tldr: payload.tldr,
            keyPoints: Array(payload.keyPoints.prefix(2)),
            quotes: payload.quotes,
            whyItMatters: payload.whyItMatters
        )
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.keyPointCountOutOfRange(count: 2)))
    }

    @Test("Flags too many key points")
    func failsOnTooManyKeyPoints() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        let extra = payload.keyPoints + payload.keyPoints + payload.keyPoints
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: extra, quotes: payload.quotes, whyItMatters: payload.whyItMatters)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.keyPointCountOutOfRange(count: extra.count)))
    }

    @Test("Flags a key point whose citation has empty supporting text")
    func failsOnKeyPointMissingCitation() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        var keyPoints = payload.keyPoints
        keyPoints[0] = WebSummaryKeyPoint(text: "Ungrounded point", citation: Self.citation("   "))
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: keyPoints, quotes: payload.quotes, whyItMatters: payload.whyItMatters)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.keyPointMissingCitation(index: 0)))
    }

    @Test("Flags too few quotes")
    func failsOnTooFewQuotes() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: payload.keyPoints, quotes: [], whyItMatters: payload.whyItMatters)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.quoteCountOutOfRange(count: 0)))
    }

    @Test("Flags a present-but-empty Why This Matters array (should have been omitted or null)")
    func failsOnEmptyWhyItMatters() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: payload.keyPoints, quotes: payload.quotes, whyItMatters: [])
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.emptyWhyItMatters))
    }

    @Test("A nil Why This Matters (omitted section) is NOT an issue")
    func nilWhyItMattersIsFine() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: payload.keyPoints, quotes: payload.quotes, whyItMatters: nil)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(!issues.contains(.emptyWhyItMatters))
    }

    @Test("Flags a citation whose supporting text doesn't occur in the source page")
    func failsOnCitationNotFound() {
        let content = Self.content(pageText: Self.pageText)
        var payload = Self.validPayload(pageText: Self.pageText, sentences: Self.sentences)
        var keyPoints = payload.keyPoints
        keyPoints[0] = WebSummaryKeyPoint(text: "Fabricated point", citation: Self.citation("text nowhere on the page"))
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: keyPoints, quotes: payload.quotes, whyItMatters: payload.whyItMatters)
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.citationUnresolved(supportingText: "text nowhere on the page", reason: .notFoundInSource)))
    }

    @Test("Flags a citation whose supporting text is ambiguous (non-unique, even with disambiguation) on the source page")
    func failsOnAmbiguousCitation() {
        let padding = Array(repeating: "pad", count: 15).joined(separator: " ")
        let ambiguousPageText = "\(padding) target phrase \(padding) target phrase \(padding)"
        let content = Self.content(pageText: ambiguousPageText)
        let payload = WebSummaryPayload(
            tldr: "A summary.",
            keyPoints: [
                WebSummaryKeyPoint(text: "Point one", citation: Self.citation("target phrase")),
                WebSummaryKeyPoint(text: "Point two", citation: Self.citation("target phrase")),
                WebSummaryKeyPoint(text: "Point three", citation: Self.citation("target phrase")),
                WebSummaryKeyPoint(text: "Point four", citation: Self.citation("target phrase")),
                WebSummaryKeyPoint(text: "Point five", citation: Self.citation("target phrase"))
            ],
            quotes: [
                WebSummaryQuote(citation: Self.citation("target phrase")),
                WebSummaryQuote(citation: Self.citation("target phrase"))
            ],
            whyItMatters: nil
        )
        let issues = WebSummaryValidator.validate(payload: payload, content: content)
        #expect(issues.contains(.citationUnresolved(supportingText: "target phrase", reason: .ambiguousInSource)))
    }
}
