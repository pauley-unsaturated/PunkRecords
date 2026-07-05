import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("VaultSearchDisplay")
struct VaultSearchDisplayTests {

    // MARK: - Snippet parsing / highlight ranges

    /// Extract the highlighted substrings so range assertions read as the
    /// matched terms rather than opaque String.Index pairs.
    private func highlightedTerms(_ h: SearchSnippet.Highlighted) -> [String] {
        h.highlightRanges.map { String(h.text[$0]) }
    }

    @Test("Plain text with no markers passes through with no highlights")
    func noMarkers() {
        let h = SearchSnippet.parse(marked: "just some plain text")
        #expect(h.text == "just some plain text")
        #expect(h.highlightRanges.isEmpty)
        #expect(h.segments == [SearchSnippet.Segment(text: "just some plain text", isHighlighted: false)])
    }

    @Test("Markers are stripped and their spans become highlight ranges")
    func balancedMarkers() {
        let h = SearchSnippet.parse(marked: "the <mark>quick</mark> brown <mark>fox</mark>")
        #expect(h.text == "the quick brown fox")
        #expect(highlightedTerms(h) == ["quick", "fox"])
    }

    @Test("A single marked term at the start highlights just that term")
    func markerAtStart() {
        let h = SearchSnippet.parse(marked: "<mark>Actors</mark> and async/await")
        #expect(h.text == "Actors and async/await")
        #expect(highlightedTerms(h) == ["Actors"])
        // Range is anchored at the very start of the text.
        #expect(h.highlightRanges.first?.lowerBound == h.text.startIndex)
    }

    @Test("Leading FTS ellipsis and punctuation survive parsing intact")
    func ellipsisPreserved() {
        let h = SearchSnippet.parse(marked: "...structured <mark>concurrency</mark> in Swift.")
        #expect(h.text == "...structured concurrency in Swift.")
        #expect(highlightedTerms(h) == ["concurrency"])
    }

    @Test("Empty excerpt yields an empty, segment-less snippet")
    func emptyExcerpt() {
        let h = SearchSnippet.parse(marked: "")
        #expect(h.text.isEmpty)
        #expect(h.isEmpty)
        #expect(h.segments.isEmpty)
    }

    @Test("Dangling open marker highlights through to end-of-text")
    func danglingOpenMarker() {
        let h = SearchSnippet.parse(marked: "start <mark>unterminated tail")
        #expect(h.text == "start unterminated tail")
        #expect(highlightedTerms(h) == ["unterminated tail"])
    }

    @Test("Segments interleave plain and highlighted runs in order")
    func segmentInterleaving() {
        let h = SearchSnippet.parse(marked: "a <mark>b</mark> c <mark>d</mark>")
        #expect(h.segments == [
            SearchSnippet.Segment(text: "a ", isHighlighted: false),
            SearchSnippet.Segment(text: "b", isHighlighted: true),
            SearchSnippet.Segment(text: " c ", isHighlighted: false),
            SearchSnippet.Segment(text: "d", isHighlighted: true),
        ])
    }

    // MARK: - Display-model mapping

    private func result(
        title: String,
        path: String,
        excerpt: String,
        score: Float
    ) -> SearchResult {
        SearchResult(documentID: UUID(), title: title, path: path, excerpt: excerpt, score: score)
    }

    @Test("Mapping preserves index order (BM25 relevance) 1:1")
    func mappingPreservesOrder() {
        let results = [
            result(title: "First", path: "a.md", excerpt: "x", score: 3.0),
            result(title: "Second", path: "b.md", excerpt: "y", score: 2.0),
            result(title: "Third", path: "c.md", excerpt: "z", score: 1.0),
        ]
        let items = VaultSearchDisplay.items(from: results)
        #expect(items.map(\.title) == ["First", "Second", "Third"])
        #expect(items.map(\.documentID) == results.map(\.documentID))
        #expect(items.count == 3)
    }

    @Test("Mapping strips excerpt markers into snippet + highlight ranges")
    func mappingBuildsHighlightedSnippet() throws {
        let items = VaultSearchDisplay.items(from: [
            result(title: "Note", path: "n.md", excerpt: "see <mark>actors</mark> here", score: 1),
        ])
        let item = try #require(items.first)
        #expect(item.snippet == "see actors here")
        #expect(item.hasSnippet)
        #expect(item.snippetSegments.contains(SearchSnippet.Segment(text: "actors", isHighlighted: true)))
    }

    @Test("A metadata-only hit (empty excerpt) maps to a snippet-less item")
    func metadataOnlyItemHasNoSnippet() throws {
        let items = VaultSearchDisplay.items(from: [
            result(title: "Tagged", path: "folder/tagged.md", excerpt: "", score: 0),
        ])
        let item = try #require(items.first)
        #expect(!item.hasSnippet)
        #expect(item.snippetSegments.isEmpty)
        #expect(item.folder == "folder")
    }

    @Test("id is the path, and folder falls back to / for vault-root notes")
    func idAndFolder() throws {
        let items = VaultSearchDisplay.items(from: [
            result(title: "Root", path: "root.md", excerpt: "", score: 0),
        ])
        let item = try #require(items.first)
        #expect(item.id == "root.md")
        #expect(item.folder == "/")
    }

    @Test("An empty title falls back to the filename stem")
    func titleFallsBackToFilename() {
        let items = VaultSearchDisplay.items(from: [
            result(title: "", path: "Daily/2026-07-04.md", excerpt: "hi", score: 1),
        ])
        #expect(items.first?.title == "2026-07-04")
    }

    // MARK: - List navigation

    @Test("clampIndex bounds the selection into the list")
    func clampIndexBounds() {
        #expect(VaultSearchDisplay.clampIndex(-3, count: 5) == 0)
        #expect(VaultSearchDisplay.clampIndex(2, count: 5) == 2)
        #expect(VaultSearchDisplay.clampIndex(9, count: 5) == 4)
        #expect(VaultSearchDisplay.clampIndex(0, count: 0) == 0)
    }

    @Test("move steps selection and clamps at the ends (no wrap)")
    func moveClampsAtEnds() {
        #expect(VaultSearchDisplay.move(selection: 0, by: 1, count: 3) == 1)
        #expect(VaultSearchDisplay.move(selection: 2, by: 1, count: 3) == 2) // clamps at bottom
        #expect(VaultSearchDisplay.move(selection: 0, by: -1, count: 3) == 0) // clamps at top
        #expect(VaultSearchDisplay.move(selection: 1, by: -1, count: 3) == 0)
        #expect(VaultSearchDisplay.move(selection: 0, by: 1, count: 0) == 0) // empty list
    }
}
