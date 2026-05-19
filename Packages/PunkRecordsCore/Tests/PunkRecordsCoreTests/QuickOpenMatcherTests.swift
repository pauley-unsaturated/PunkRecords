import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("QuickOpenMatcher Tests")
struct QuickOpenMatcherTests {
    private func doc(_ title: String, path: String? = nil) -> Document {
        Document(
            id: UUID(),
            title: title,
            content: "",
            path: path ?? "\(title).md",
            tags: [],
            created: Date(),
            modified: Date(),
            frontmatter: [:],
            linkedDocumentIDs: []
        )
    }

    @Test("Empty query returns documents in vault title order, up to limit")
    func emptyQueryReturnsAll() {
        let docs = [doc("Beta"), doc("Alpha"), doc("Gamma")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "", limit: 25)
        #expect(matches.count == 3)
        #expect(matches.map(\.document.title) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("Empty query respects limit")
    func emptyQueryLimited() {
        let docs = (0..<50).map { doc("Note \($0)") }
        let matches = QuickOpenMatcher.match(documents: docs, query: "", limit: 10)
        #expect(matches.count == 10)
    }

    @Test("Exact prefix scores highest")
    func exactPrefix() {
        let docs = [doc("Refactor Notes"), doc("Daily Ref"), doc("ref")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "ref")
        #expect(matches.first?.document.title == "ref")
    }

    @Test("Word-boundary match outranks mid-word match")
    func wordBoundaryWins() {
        let docs = [doc("Frobulated"), doc("Foo Bar")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "fb")
        #expect(matches.first?.document.title == "Foo Bar")
    }

    @Test("Subsequence match works (non-contiguous)")
    func subsequence() {
        let docs = [doc("Hello World")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "hwd")
        #expect(matches.count == 1)
        // 'h' at 0, 'w' at 6, 'd' at 10
        #expect(matches.first?.matchedIndices == [0, 6, 10])
    }

    @Test("Non-matching query returns no results")
    func noMatch() {
        let docs = [doc("Apple"), doc("Banana")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "xyz")
        #expect(matches.isEmpty)
    }

    @Test("Case insensitive")
    func caseInsensitive() {
        let docs = [doc("MyNote"), doc("mynote")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "MN")
        #expect(matches.count == 2)
    }

    @Test("Matched indices align with the title for highlighting")
    func matchedIndices() {
        let docs = [doc("Foo Bar Baz")]
        let matches = QuickOpenMatcher.match(documents: docs, query: "fbb")
        #expect(matches.first?.matchedIndices == [0, 4, 8])
    }

    @Test("Consecutive run scores higher than non-consecutive without word boundaries")
    func consecutiveBonus() {
        // Both lack word boundaries — consecutive run is the only signal that differs.
        let consecutive = [doc("apple")]
        let scattered = [doc("axxpxxpxxl")]
        let mc = QuickOpenMatcher.match(documents: consecutive, query: "appl").first!
        let ms = QuickOpenMatcher.match(documents: scattered, query: "appl").first!
        #expect(mc.score > ms.score)
    }

    @Test("Shorter title wins on score tie")
    func shorterWinsOnTie() {
        let docs = [
            doc("Foo Bar Baz Qux"),
            doc("Foo"),
        ]
        let matches = QuickOpenMatcher.match(documents: docs, query: "foo")
        #expect(matches.first?.document.title == "Foo")
    }
}
