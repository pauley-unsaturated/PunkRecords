import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("LongFormChunkPlanner — H2 splitting with size-based fallback")
struct LongFormChunkPlannerTests {

    /// A paragraph long enough to be a meaningful chunk of text on its own —
    /// repeated to build up token counts deterministically.
    private static func paragraph(_ seed: Int) -> String {
        "Paragraph \(seed) discusses the subject in some depth, with enough words and clauses "
            + "to resemble real prose rather than a placeholder, repeated so the token estimate "
            + "climbs steadily across many paragraphs in this synthetic long document fixture."
    }

    private static func section(_ title: String, paragraphCount: Int, seedStart: Int) -> String {
        let paragraphs = (0..<paragraphCount).map { paragraph(seedStart + $0) }
        return "## \(title)\n\n" + paragraphs.joined(separator: "\n\n")
    }

    // MARK: - isLongForm

    @Test("A short document is not long-form")
    func shortDocumentIsNotLongForm() {
        #expect(!LongFormChunkPlanner.isLongForm(bodyText: "Just a short paragraph of text."))
    }

    @Test("A document estimated over the threshold is long-form")
    func overThresholdIsLongForm() {
        // ~4 chars/token, so ~210k chars comfortably clears the 50k-token bar.
        let huge = String(repeating: "word ", count: 45_000)
        #expect(LongFormChunkPlanner.isLongForm(bodyText: huge))
    }

    @Test("isLongForm boundary matches TokenEstimator directly")
    func boundaryMatchesTokenEstimator() {
        let text = String(repeating: "x", count: (LongFormChunkPlanner.longFormTokenThreshold + 1) * 4)
        #expect(TokenEstimator.estimateTokens(in: text) > LongFormChunkPlanner.longFormTokenThreshold)
        #expect(LongFormChunkPlanner.isLongForm(bodyText: text))
    }

    // MARK: - H2 splitting

    @Test("Splits into per-H2 sections when the document has multiple H2 headings")
    func splitsPerH2() {
        let sections = (1...5).map { section("Section \($0)", paragraphCount: 3, seedStart: $0 * 10) }
        let doc = sections.joined(separator: "\n\n")
        let plan = LongFormChunkPlanner.plan(bodyText: doc)

        #expect(plan.strategy == .perH2Section)
        #expect(plan.chunks.count == 5)
        #expect(plan.chunks.map(\.heading) == (1...5).map { "Section \($0)" })
        #expect(plan.chunks.map(\.index) == Array(0..<5))
        #expect(plan.totalEstimatedTokens == plan.chunks.reduce(0) { $0 + $1.estimatedTokens })
    }

    @Test("Text before the first H2 becomes a headingless preamble chunk")
    func preambleBeforeFirstH2() {
        let doc = "Some intro text before any heading, long enough to be its own real preamble chunk here.\n\n"
            + section("First", paragraphCount: 2, seedStart: 1) + "\n\n"
            + section("Second", paragraphCount: 2, seedStart: 100)
        let plan = LongFormChunkPlanner.plan(bodyText: doc)

        #expect(plan.strategy == .perH2Section)
        #expect(plan.chunks.count == 3)
        #expect(plan.chunks[0].heading == nil)
        #expect(plan.chunks[0].markdown.contains("Some intro text"))
        #expect(plan.chunks[1].heading == "First")
        #expect(plan.chunks[2].heading == "Second")
    }

    @Test("An H3 heading does not count as an H2 split point")
    func h3DoesNotSplit() {
        let doc = "## Only Section\n\nIntro paragraph here with enough words to be real content for the test.\n\n"
            + "### A Subheading\n\nMore text under the subheading, still part of the same top-level H2 section."
        let plan = LongFormChunkPlanner.plan(bodyText: doc)
        // Only ONE H2 → not ">1" sections → falls back to size-based, not perH2Section.
        #expect(plan.strategy == .sizeBased)
    }

    @Test("An oversized single H2 section is further split by size, keeping its heading")
    func oversizedSectionFurtherSplit() {
        let big = section("Massive Section", paragraphCount: 400, seedStart: 1)
        let small = section("Tiny Section", paragraphCount: 2, seedStart: 900)
        let doc = big + "\n\n" + small
        let plan = LongFormChunkPlanner.plan(bodyText: doc)

        #expect(plan.strategy == .perH2Section)
        #expect(plan.chunks.count > 2) // the massive section got split into multiple pieces
        let massiveChunks = plan.chunks.filter { $0.heading == "Massive Section" }
        #expect(massiveChunks.count > 1)
        for chunk in massiveChunks {
            #expect(chunk.estimatedTokens <= LongFormChunkPlanner.maxChunkTokens)
        }
        #expect(plan.chunks.last?.heading == "Tiny Section")
    }

    // MARK: - Size-based fallback

    @Test("Falls back to size-based chunking when there are no H2 headings at all")
    func sizeBasedFallbackNoHeadings() {
        // 400 paragraphs (~60 tokens each) comfortably exceeds one 8k-token
        // chunk, so this must split into multiple size-based chunks.
        let paragraphs = (0..<400).map { paragraph($0) }
        let doc = paragraphs.joined(separator: "\n\n")
        let plan = LongFormChunkPlanner.plan(bodyText: doc)

        #expect(plan.strategy == .sizeBased)
        #expect(plan.chunks.count > 1)
        #expect(plan.chunks.allSatisfy { $0.heading == nil })
        for chunk in plan.chunks {
            #expect(chunk.estimatedTokens <= LongFormChunkPlanner.targetChunkTokens)
        }
    }

    @Test("A single paragraph that alone exceeds the budget becomes its own oversized chunk")
    func singleOversizedParagraphIsNotSplitMidSentence() {
        let hugeParagraph = String(repeating: "word ", count: 40_000) // no blank lines inside
        let plan = LongFormChunkPlanner.plan(bodyText: hugeParagraph)
        #expect(plan.chunks.count == 1)
        #expect(plan.chunks[0].markdown == hugeParagraph.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Chunk plan total token estimate sums the per-chunk estimates")
    func totalTokensSumsChunks() {
        let doc = (0..<20).map { paragraph($0) }.joined(separator: "\n\n")
        let plan = LongFormChunkPlanner.plan(bodyText: doc)
        #expect(plan.totalEstimatedTokens == plan.chunks.reduce(0) { $0 + $1.estimatedTokens })
    }
}
