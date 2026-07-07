import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebSummaryPostProcessor — parses LLM JSON and renders the 4-section citation markdown")
struct WebSummaryPostProcessorTests {

    // MARK: - Fixtures

    private static let sentence1 = "Widgets are small mechanical parts used in many devices."
    private static let sentence2 = "Engineers assemble widgets by hand at the factory."
    private static let sentence3 = "Quality control inspects every widget before shipping."
    private static let sentence4 = "Customers order widgets online through the storefront."
    private static let sentence5 = "The factory produces about five hundred widgets daily."
    private static let sentence6 = "Widgets ship worldwide within two business days."

    private static func widgetContent() -> WebContent {
        let pageText = [sentence1, sentence2, sentence3, sentence4, sentence5, sentence6]
            .joined(separator: " ")
        return WebContent(
            title: "Widget Manufacturing",
            byline: "Jane Doe",
            contentMarkdown: pageText,
            headings: [WebHeading(level: 1, text: "Widget Manufacturing", anchorID: "widget-manufacturing")],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: URL(string: "https://example.com/widgets")!,
            canonicalURL: nil
        )
    }

    private static func citation(_ text: String, index: Int, anchor: String? = "widget-manufacturing") -> WebSummaryCitation {
        WebSummaryCitation(citationIndex: index, supportingText: text, nearestHeadingAnchor: anchor)
    }

    private static func goldenPayload() -> WebSummaryPayload {
        WebSummaryPayload(
            tldr: "Widgets are manufactured by hand and shipped worldwide within two days.",
            keyPoints: [
                WebSummaryKeyPoint(text: "Widgets are small mechanical parts.", citation: citation(sentence1, index: 1)),
                WebSummaryKeyPoint(text: "Engineers assemble widgets by hand.", citation: citation(sentence2, index: 2)),
                WebSummaryKeyPoint(text: "Every widget is quality inspected.", citation: citation(sentence3, index: 3)),
                WebSummaryKeyPoint(text: "Customers order online.", citation: citation(sentence4, index: 4)),
                WebSummaryKeyPoint(text: "About five hundred widgets are made daily.", citation: citation(sentence5, index: 5))
            ],
            quotes: [
                WebSummaryQuote(citation: citation(sentence6, index: 6)),
                // Deliberately duplicates key point #1's citation to exercise dedup.
                WebSummaryQuote(citation: citation(sentence1, index: 7))
            ],
            whyItMatters: ["Manual assembly could become a bottleneck as demand grows."]
        )
    }

    // MARK: - Golden path

    @Test("Renders the exact 4-section markdown, deterministic footnote numbering, and citation dedup")
    func goldenPathRender() {
        let content = Self.widgetContent()
        let payload = Self.goldenPayload()

        let e1 = TextFragmentBuilder.percentEncode(Self.sentence1)
        let e2 = TextFragmentBuilder.percentEncode(Self.sentence2)
        let e3 = TextFragmentBuilder.percentEncode(Self.sentence3)
        let e4 = TextFragmentBuilder.percentEncode(Self.sentence4)
        let e5 = TextFragmentBuilder.percentEncode(Self.sentence5)
        let e6 = TextFragmentBuilder.percentEncode(Self.sentence6)

        let expected = """
        ## TL;DR

        Widgets are manufactured by hand and shipped worldwide within two days.

        ## Key Points

        - Widgets are small mechanical parts. [¹]
        - Engineers assemble widgets by hand. [²]
        - Every widget is quality inspected. [³]
        - Customers order online. [⁴]
        - About five hundred widgets are made daily. [⁵]

        ## Notable Quotes

        > "Widgets ship worldwide within two business days." [⁶]

        > "Widgets are small mechanical parts used in many devices." [¹]

        ## Why This Matters

        - Manual assembly could become a bottleneck as demand grows.

        ## Sources

        1. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e1)) — "Widgets are small mechanical parts used in many devices."
        2. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e2)) — "Engineers assemble widgets by hand at the factory."
        3. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e3)) — "Quality control inspects every widget before shipping."
        4. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e4)) — "Customers order widgets online through the storefront."
        5. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e5)) — "The factory produces about five hundred widgets daily."
        6. [Widget Manufacturing](https://example.com/widgets#:~:text=\(e6)) — "Widgets ship worldwide within two business days."

        """

        let rendered = WebSummaryPostProcessor.render(payload: payload, content: content)
        #expect(rendered.markdown == expected)
        #expect(rendered.unresolvedCitationCount == 0)
    }

    @Test("Rendering is deterministic: repeated calls with the same input produce byte-identical markdown")
    func renderIsDeterministic() {
        let content = Self.widgetContent()
        let payload = Self.goldenPayload()
        let first = WebSummaryPostProcessor.render(payload: payload, content: content).markdown
        let second = WebSummaryPostProcessor.render(payload: payload, content: content).markdown
        #expect(first == second)
    }

    @Test("Omits the Why This Matters section entirely when whyItMatters is nil")
    func omitsWhyItMattersWhenNil() {
        let content = Self.widgetContent()
        var payload = Self.goldenPayload()
        payload = WebSummaryPayload(tldr: payload.tldr, keyPoints: payload.keyPoints, quotes: payload.quotes, whyItMatters: nil)
        let rendered = WebSummaryPostProcessor.render(payload: payload, content: content)
        #expect(!rendered.markdown.contains("Why This Matters"))
    }

    // MARK: - Parsing

    @Test("Parses a well-formed raw JSON response")
    func parsesWellFormedJSON() throws {
        let raw = """
        {
          "tldr": "A summary.",
          "key_points": [
            {
              "text": "Point one",
              "citation": {"citation_index": 1, "supporting_text": "foo", "nearest_heading_anchor": null}
            }
          ],
          "quotes": [],
          "why_it_matters": null
        }
        """
        let payload = try WebSummaryPostProcessor.parse(raw)
        #expect(payload.tldr == "A summary.")
        #expect(payload.keyPoints.count == 1)
        #expect(payload.keyPoints[0].citation.nearestHeadingAnchor == nil)
    }

    @Test("Tolerates a ```json ... ``` fence wrapping the JSON despite the prompt asking not to")
    func tolerantOfCodeFence() throws {
        let raw = """
        ```json
        {"tldr":"A summary.","key_points":[],"quotes":[],"why_it_matters":null}
        ```
        """
        let payload = try WebSummaryPostProcessor.parse(raw)
        #expect(payload.tldr == "A summary.")
    }

    @Test("Throws emptyResponse for a blank response")
    func emptyResponseThrows() {
        #expect(throws: WebSummaryPostProcessor.ParseError.emptyResponse) {
            _ = try WebSummaryPostProcessor.parse("   \n  ")
        }
    }

    @Test("Throws invalidJSON for malformed JSON")
    func malformedJSONThrows() throws {
        #expect(throws: WebSummaryPostProcessor.ParseError.self) {
            _ = try WebSummaryPostProcessor.parse("{not valid json")
        }
        do {
            _ = try WebSummaryPostProcessor.parse("{not valid json")
            Issue.record("Expected parse to throw")
        } catch let error as WebSummaryPostProcessor.ParseError {
            guard case .invalidJSON = error else {
                Issue.record("Expected .invalidJSON, got \(error)")
                return
            }
        }
    }

    @Test("Throws invalidJSON when a required field (key_points) is missing from the JSON")
    func missingRequiredFieldThrows() throws {
        let raw = """
        {"tldr":"A summary.","quotes":[],"why_it_matters":null}
        """
        #expect(throws: WebSummaryPostProcessor.ParseError.self) {
            _ = try WebSummaryPostProcessor.parse(raw)
        }
        do {
            _ = try WebSummaryPostProcessor.parse(raw)
            Issue.record("Expected parse to throw")
        } catch let error as WebSummaryPostProcessor.ParseError {
            guard case .invalidJSON = error else {
                Issue.record("Expected .invalidJSON, got \(error)")
                return
            }
        }
    }

    // MARK: - Citation resolution edge cases

    @Test("A citation pointing at text absent from the page still renders, with a plain (non-fragment) link, and is counted unresolved")
    func citationAbsentFromPageFallsBackToPlainLink() {
        let content = Self.widgetContent()
        var payload = Self.goldenPayload()
        let badKeyPoint = WebSummaryKeyPoint(
            text: "A point that isn't really grounded.",
            citation: Self.citation("this text does not appear on the page anywhere", index: 99)
        )
        payload = WebSummaryPayload(
            tldr: payload.tldr,
            keyPoints: [badKeyPoint] + payload.keyPoints.dropLast(),
            quotes: payload.quotes,
            whyItMatters: payload.whyItMatters
        )

        let rendered = WebSummaryPostProcessor.render(payload: payload, content: content)
        #expect(rendered.unresolvedCitationCount == 1)
        #expect(rendered.markdown.contains("1. [Widget Manufacturing](https://example.com/widgets) — \"this text does not appear on the page anywhere\""))
        // Every OTHER (resolved) source line still carries a text fragment.
        #expect(rendered.markdown.contains("#:~:text="))
    }

    @Test("A quote over 30 words is truncated (not rejected): displayed with a trailing ellipsis, matched on the first 30 words")
    func longQuoteIsTruncated() {
        let words = (1...40).map { "word\($0)" }
        let longSentence = words.joined(separator: " ") + "."
        let content = WebContent(
            title: "Long Quote Page",
            byline: nil,
            contentMarkdown: "Intro text. \(longSentence) Outro text.",
            headings: [],
            extractedAt: Date(timeIntervalSince1970: 0),
            tier: .readability,
            sourceURL: URL(string: "https://example.com/long")!,
            canonicalURL: nil
        )
        let payload = WebSummaryPayload(
            tldr: "A long quote page.",
            keyPoints: [],
            quotes: [WebSummaryQuote(citation: Self.citation(longSentence, index: 1, anchor: nil))],
            whyItMatters: nil
        )

        let rendered = WebSummaryPostProcessor.render(payload: payload, content: content)
        let expectedMatchText = words.prefix(30).joined(separator: " ")
        let expectedDisplayText = expectedMatchText + "…"

        #expect(rendered.markdown.contains("> \"\(expectedDisplayText)\" [¹]"))
        #expect(rendered.unresolvedCitationCount == 0)
        #expect(rendered.markdown.contains(TextFragmentBuilder.percentEncode(expectedMatchText)))
        // The untruncated 40-word sentence must NOT appear in the emitted fragment.
        #expect(!rendered.markdown.contains(TextFragmentBuilder.percentEncode(longSentence)))
    }

    // MARK: - superscript / previewText / extractJSON internals

    @Test("superscript renders multi-digit numbers digit-by-digit")
    func superscriptMultiDigit() {
        #expect(WebSummaryPostProcessor.superscript(1) == "¹")
        #expect(WebSummaryPostProcessor.superscript(9) == "⁹")
        #expect(WebSummaryPostProcessor.superscript(10) == "¹⁰")
        #expect(WebSummaryPostProcessor.superscript(123) == "¹²³")
    }

    @Test("previewText truncates long text with a trailing ellipsis and leaves short text untouched")
    func previewTextTruncation() {
        let short = "A short excerpt."
        #expect(WebSummaryPostProcessor.previewText(short) == short)

        let long = String(repeating: "x", count: 200)
        let preview = WebSummaryPostProcessor.previewText(long, maxLength: 140)
        #expect(preview.hasSuffix("…"))
        #expect(preview.count == 141) // 140 chars + ellipsis
    }
}
