import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebSummaryNoteWriter — assembles the Web/ note schema from a fetched+summarized page")
struct WebSummaryNoteWriterTests {

    // MARK: - Fixtures

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_100_000) // 2023-11-16T02:40:00Z
    private static let fixedExtractedAt = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    private static let fixedID = DocumentID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private static func content(
        title: String = "Widget Manufacturing",
        byline: String? = "Jane Doe",
        url: String = "https://example.com/widgets",
        tier: WebFetchTier = .readability
    ) -> WebContent {
        WebContent(
            title: title,
            byline: byline,
            contentMarkdown: "Widgets are small mechanical parts used in many devices.",
            headings: [WebHeading(level: 1, text: title, anchorID: "widget-manufacturing")],
            extractedAt: fixedExtractedAt,
            tier: tier,
            sourceURL: URL(string: url)!,
            canonicalURL: nil
        )
    }

    private static func summaryResult(
        markdown: String = "## TL;DR\n\nWidgets are manufactured by hand.\n",
        unresolvedCitationCount: Int = 0
    ) -> WebSummaryPostProcessor.Result {
        let payload = WebSummaryPayload(
            tldr: "Widgets are manufactured by hand.",
            keyPoints: [],
            quotes: [],
            whyItMatters: nil
        )
        return WebSummaryPostProcessor.Result(
            markdown: markdown,
            payload: payload,
            unresolvedCitationCount: unresolvedCitationCount
        )
    }

    // MARK: - Snapshot

    @Test("Snapshot: full note markdown for a golden fixture, exact byte match")
    func snapshotGoldenNote() {
        let iso = ISO8601DateFormatter()
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "claude-sonnet-4-6",
            tags: ["manufacturing"],
            now: Self.fixedNow,
            id: Self.fixedID
        )

        #expect(output.path == "Web/2023-11-16-widget-manufacturing.md")
        #expect(output.title == "Widget Manufacturing")
        #expect(output.tags == ["manufacturing", "web-summary"])
        #expect(output.id == Self.fixedID)

        let expected = """
        ---
        id: \(Self.fixedID.uuidString)
        created: \(iso.string(from: Self.fixedNow))
        modified: \(iso.string(from: Self.fixedNow))
        title: "Widget Manufacturing"
        source_url: "https://example.com/widgets"
        source_domain: "example.com"
        author: "Jane Doe"
        tags: [manufacturing, web-summary]
        type: web-summary
        status: "unread"
        _punkrecords:
          fetched: "\(iso.string(from: Self.fixedExtractedAt))"
          fetcher: "readability"
          summary_model: "claude-sonnet-4-6"
          summary_prompt_version: "web-summary-v1"
          word_count: 7
          reading_time_min: 1
          validator_issue_count: 0
          unresolved_citation_count: 0
        ---

        # Widget Manufacturing

        ## TL;DR

        Widgets are manufactured by hand.

        """
        #expect(output.markdown == expected)
    }

    // MARK: - Slug collision

    @Test("Collision on the same date+slug numeric-suffixes the path")
    func slugCollision() {
        let first = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        let second = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow,
            existingPaths: [first.path]
        )
        let third = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow,
            existingPaths: [first.path, second.path]
        )

        #expect(first.path == "Web/2023-11-16-widget-manufacturing.md")
        #expect(second.path == "Web/2023-11-16-widget-manufacturing-2.md")
        #expect(third.path == "Web/2023-11-16-widget-manufacturing-3.md")
    }

    @Test("No collision when existingPaths doesn't contain the candidate")
    func noCollisionWhenPathUnused() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow,
            existingPaths: ["Web/2023-11-16-some-other-page.md"]
        )
        #expect(output.path == "Web/2023-11-16-widget-manufacturing.md")
    }

    // MARK: - Weird titles

    @Test("Emoji in the title fold out of the slug but survive in frontmatter title")
    func emojiTitle() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(title: "🎉 Party Time! 🎉"),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.path == "Web/2023-11-16-party-time.md")
        #expect(output.title == "🎉 Party Time! 🎉")
        #expect(output.markdown.contains("title: \"🎉 Party Time! 🎉\""))
    }

    @Test("Slashes in the title never produce extra path components")
    func slashesInTitle() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(title: "A/B Testing: Best Practices"),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        // Exactly one slash: the Web/ folder separator.
        #expect(output.path.filter { $0 == "/" }.count == 1)
        #expect(output.path.hasPrefix("Web/"))
        #expect(output.path.hasSuffix(".md"))
    }

    @Test("A very long title produces a bounded, hyphen-clean slug")
    func veryLongTitle() {
        let longTitle = Array(repeating: "supercalifragilistic", count: 10).joined(separator: " ")
        let output = WebSummaryNoteWriter.write(
            content: Self.content(title: longTitle),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        let filename = (output.path as NSString).lastPathComponent
        let slugPortion = filename
            .replacingOccurrences(of: "2023-11-16-", with: "")
            .replacingOccurrences(of: ".md", with: "")
        #expect(slugPortion.count <= WebSummaryNoteWriter.maxSlugLength)
        #expect(!slugPortion.hasSuffix("-"))
        #expect(!slugPortion.isEmpty)
        // Full (unsanitized) title still survives in frontmatter, untruncated.
        #expect(output.markdown.contains(longTitle))
    }

    @Test("An empty/blank title falls back to Untitled")
    func blankTitleFallsBack() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(title: "   "),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.title == "Untitled")
        #expect(output.path == "Web/2023-11-16-untitled.md")
    }

    // MARK: - Missing author / published

    @Test("author key is omitted when there's no byline and none is passed explicitly")
    func missingAuthorOmitted() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(byline: nil),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(!output.markdown.contains("author:"))
    }

    @Test("author falls back to content.byline when not passed explicitly")
    func authorFallsBackToByline() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(byline: "Ada Lovelace"),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("author: \"Ada Lovelace\""))
    }

    @Test("An explicit author overrides content.byline")
    func explicitAuthorOverridesByline() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(byline: "Byline Author"),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            author: "Explicit Author",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("author: \"Explicit Author\""))
        #expect(!output.markdown.contains("Byline Author"))
    }

    @Test("published key is omitted when nil (the current pipeline default)")
    func missingPublishedOmitted() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(!output.markdown.contains("published:"))
    }

    @Test("published key is present and ISO8601-formatted when supplied")
    func publishedPresentWhenSupplied() {
        let iso = ISO8601DateFormatter()
        let publishedDate = Date(timeIntervalSince1970: 1_699_000_000)
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            published: publishedDate,
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("published: \"\(iso.string(from: publishedDate))\""))
    }

    // MARK: - _punkrecords namespacing

    @Test("Implementation details are namespaced under _punkrecords, not at the top level")
    func punkrecordsNamespacing() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 2,
            summaryModel: "claude-sonnet-4-6",
            now: Self.fixedNow
        )

        let lines = output.markdown.components(separatedBy: "\n")
        guard let nsIndex = lines.firstIndex(of: "_punkrecords:") else {
            Issue.record("Expected a top-level `_punkrecords:` key")
            return
        }

        // The namespaced key sits at column 0 (unindented) ...
        #expect(!lines[nsIndex].hasPrefix(" "))
        // ... while every implementation-detail line under it is indented.
        let nestedKeys = ["fetched", "fetcher", "summary_model", "summary_prompt_version",
                           "word_count", "reading_time_min", "validator_issue_count", "unresolved_citation_count"]
        for key in nestedKeys {
            guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) else {
                Issue.record("Expected nested key '\(key)' under _punkrecords:")
                continue
            }
            #expect(line.hasPrefix("  "), "Expected '\(key)' to be indented under _punkrecords:")
        }

        // User-facing fields are NOT nested (appear unindented, at column 0).
        let topLevelKeys = ["title", "source_url", "source_domain", "tags", "type", "status"]
        for key in topLevelKeys {
            guard let line = lines.first(where: { $0.hasPrefix("\(key):") }) else {
                Issue.record("Expected top-level key '\(key)' to be unindented")
                continue
            }
            #expect(!line.hasPrefix(" "))
        }

        #expect(output.markdown.contains("validator_issue_count: 2"))
    }

    @Test("type is always the literal web-summary")
    func typeIsAlwaysWebSummary() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("type: web-summary"))
    }

    // MARK: - Tags

    @Test("web-summary tag is always present even when no tags are passed")
    func baseTagAlwaysPresent() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.tags == ["web-summary"])
    }

    @Test("Tags are lowercased and deduped")
    func tagsLowercasedAndDeduped() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            tags: ["AI", "ai", "Web-Summary", " Design "],
            now: Self.fixedNow
        )
        #expect(output.tags == ["ai", "web-summary", "design"])
    }

    // MARK: - Word count / reading time

    @Test("word_count and reading_time_min are derived from the summary body, not the source article")
    func wordCountFromSummaryBody() {
        let words = Array(repeating: "word", count: 450).joined(separator: " ")
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(markdown: words),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("word_count: 450"))
        // 450 / 200 = 2.25 -> rounds up to 3.
        #expect(output.markdown.contains("reading_time_min: 3"))
    }

    @Test("reading_time_min is never zero, even for a tiny summary")
    func readingTimeNeverZero() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(),
            summary: Self.summaryResult(markdown: "Short."),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains("reading_time_min: 1"))
    }

    // MARK: - YAML quoting safety

    @Test("A title containing a colon and quotes is safely escaped")
    func titleWithColonAndQuotes() {
        let output = WebSummaryNoteWriter.write(
            content: Self.content(title: "The \"Best\" Guide: A Review"),
            summary: Self.summaryResult(),
            validatorIssueCount: 0,
            summaryModel: "m",
            now: Self.fixedNow
        )
        #expect(output.markdown.contains(#"title: "The \"Best\" Guide: A Review""#))
    }
}
