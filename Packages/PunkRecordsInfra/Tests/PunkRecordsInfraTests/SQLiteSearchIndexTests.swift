import Testing
@testable import PunkRecordsInfra
import PunkRecordsCore

@Suite("SQLite Search Index Tests")
struct SQLiteSearchIndexTests {
    @Test("Index and search a document")
    func indexAndSearch() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)

        let doc = Document(
            title: "Swift Concurrency",
            content: "# Swift Concurrency\n\nAsync/await and structured concurrency in Swift.",
            path: "swift-concurrency.md",
            tags: ["swift", "concurrency"]
        )

        try await index.index(document: doc)
        let results = try await index.search(query: "concurrency")

        #expect(!results.isEmpty)
        #expect(results.first?.documentID == doc.id)
    }

    @Test("Empty query returns empty results")
    func emptyQuery() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let results = try await index.search(query: "")
        #expect(results.isEmpty)
    }

    @Test("Remove document from index")
    func removeFromIndex() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)

        let doc = Document(
            title: "To Delete",
            content: "# To Delete\n\nThis will be removed.",
            path: "delete-me.md"
        )

        try await index.index(document: doc)
        try await index.removeFromIndex(documentID: doc.id)

        let results = try await index.search(query: "Delete")
        #expect(results.isEmpty)
    }

    // MARK: - Regression: LLM-style queries with punctuation must not crash FTS5
    //
    // Context: in agent mode the LLM calls vault_search with free-form queries
    // that often contain file paths, commas, and other punctuation. The old
    // parser passed those through unmodified and FTS5 threw a
    // `syntax error near ","` (or similar). These tests confirm the fix
    // survives a round trip through real SQLite FTS5.

    @Test("Search tolerates file path query without throwing")
    func pathQueryDoesNotCrashFTS() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Knowledge Base Reference",
            content: "# Knowledge Base\n\nCanonical notes for Flatline.",
            path: "knowledge-base.md"
        ))

        // The critical assertion is that FTS5 doesn't throw. Match semantics
        // (AND across sanitized tokens) are covered by other tests.
        _ = try await index.search(query: "/Users/markpauley/Programs/Flatline/KNOWLEDGE-BASE.md")
    }

    @Test("Search tolerates comma-separated query")
    func commaQueryDoesNotCrashFTS() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Link Guide",
            content: "Markdown links and wikilinks in PunkRecords.",
            path: "links.md"
        ))

        // This is the exact shape that originally crashed: "link, right"
        _ = try await index.search(query: "link, right")
    }

    @Test("Search tolerates user question with trailing punctuation")
    func questionQueryDoesNotCrashFTS() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Actor Reentrancy",
            content: "# Actor Reentrancy\n\nSubtle issue at suspension points.",
            path: "actor-reentrancy.md"
        ))

        _ = try await index.search(query: "What is actor reentrancy?")
    }

    @Test("Search tolerates pathological punctuation without throwing")
    func pathologicalQueryDoesNotCrashFTS() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Swift",
            content: "Swift concurrency notes.",
            path: "swift.md"
        ))

        // Pure-punctuation query should not crash — and with no alphanumeric
        // content after sanitization, should return zero results.
        let results = try await index.search(query: "/,.;:?!&|<>()[]{}~*")
        #expect(results.isEmpty)
    }

    @Test("Document is findable by a word from a noisy LLM query")
    func noisyQueryFindsMatchingWord() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Reentrancy",
            content: "Reentrancy is a subtle issue at suspension points.",
            path: "reentrancy.md"
        ))

        // A single distinctive token, even when surrounded by punctuation, still matches.
        let results = try await index.search(query: "reentrancy?")
        #expect(!results.isEmpty)
    }

    // MARK: - tag: / title: metadata filters (PUNK-ilq)

    /// Indexes a small fixed corpus used by the filter tests below.
    private func makeTaggedCorpus() async throws -> SQLiteSearchIndex {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Swift Concurrency Guide",
            content: "# Swift Concurrency\n\nActors, async/await and structured concurrency.",
            path: "swift-concurrency.md",
            tags: ["swift", "concurrency"]
        ))
        try await index.index(document: Document(
            title: "SwiftUI Layout",
            content: "# SwiftUI Layout\n\nStacks and geometry in SwiftUI.",
            path: "swiftui-layout.md",
            tags: ["swiftui", "ui"]
        ))
        try await index.index(document: Document(
            title: "Rust Ownership",
            content: "# Rust Ownership\n\nBorrow checker and lifetimes.",
            path: "rust-ownership.md",
            tags: ["rust", "concurrency"]
        ))
        return index
    }

    @Test("tag: alone returns exactly the tagged documents")
    func tagFilterReturnsTaggedDocs() async throws {
        let index = try await makeTaggedCorpus()
        let results = try await index.search(query: "tag:concurrency")
        let paths = Set(results.map(\.path))
        #expect(paths == ["swift-concurrency.md", "rust-ownership.md"])
    }

    @Test("tag: match is exact — does not substring-match related tags")
    func tagFilterIsExactNotSubstring() async throws {
        let index = try await makeTaggedCorpus()
        // "swift" must NOT match the "swiftui" tag — the classic LIKE bug.
        let results = try await index.search(query: "tag:swift")
        let paths = Set(results.map(\.path))
        #expect(paths == ["swift-concurrency.md"])
    }

    @Test("tag: filtering is case-insensitive")
    func tagFilterIsCaseInsensitive() async throws {
        let index = try await makeTaggedCorpus()
        let results = try await index.search(query: "tag:CONCURRENCY")
        #expect(Set(results.map(\.path)) == ["swift-concurrency.md", "rust-ownership.md"])
    }

    @Test("tag: with no matching tag returns nothing")
    func tagFilterNoMatch() async throws {
        let index = try await makeTaggedCorpus()
        let results = try await index.search(query: "tag:nonexistent")
        #expect(results.isEmpty)
    }

    @Test("Full-text query combined with tag: narrows to the intersection")
    func queryPlusTagFilter() async throws {
        let index = try await makeTaggedCorpus()
        // "concurrency" as free text matches all three via the concurrency tag /
        // body; the tag:swift filter narrows to the single swift-tagged doc.
        let results = try await index.search(query: "concurrency tag:swift")
        #expect(Set(results.map(\.path)) == ["swift-concurrency.md"])
    }

    @Test("Hyphenated tags round-trip through storage and exact match")
    func hyphenatedTagRoundTrips() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "DSP Notes",
            content: "# DSP\n\nFilters.",
            path: "dsp.md",
            tags: ["swift-concurrency", "audio"]
        ))
        let hit = try await index.search(query: "tag:swift-concurrency")
        #expect(hit.map(\.path) == ["dsp.md"])
        // The prefix "swift" must not match the full "swift-concurrency" tag.
        let miss = try await index.search(query: "tag:swift")
        #expect(miss.isEmpty)
    }

    @Test("Punctuation-laden tags are stored and matched without false positives")
    func punctuationTagExactMatch() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "C Plus Plus",
            content: "# C++\n\nTemplates.",
            path: "cpp.md",
            tags: ["c++"]
        ))
        try await index.index(document: Document(
            title: "C Language",
            content: "# C\n\nPointers.",
            path: "c.md",
            tags: ["c"]
        ))
        let cpp = try await index.search(query: "tag:c++")
        #expect(cpp.map(\.path) == ["cpp.md"])
        let c = try await index.search(query: "tag:c")
        #expect(c.map(\.path) == ["c.md"])
    }

    @Test("title: alone matches by case-insensitive substring")
    func titleFilterSubstringMatch() async throws {
        let index = try await makeTaggedCorpus()
        // "swift" appears in two titles ("Swift Concurrency Guide", "SwiftUI Layout").
        let results = try await index.search(query: "title:swift")
        #expect(Set(results.map(\.path)) == ["swift-concurrency.md", "swiftui-layout.md"])
    }

    @Test("title: narrows a full-text query to matching titles")
    func queryPlusTitleFilter() async throws {
        let index = try await makeTaggedCorpus()
        // Body/tag term "concurrency" matches swift + rust docs; title:Rust keeps only Rust.
        let results = try await index.search(query: "concurrency title:Rust")
        #expect(results.map(\.path) == ["rust-ownership.md"])
    }

    @Test("title: with LIKE metacharacters matches literally, not as wildcards")
    func titleFilterEscapesLikeWildcards() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "100% Coverage",
            content: "# Coverage\n\nTests.",
            path: "coverage.md"
        ))
        try await index.index(document: Document(
            title: "Plain Title",
            content: "# Plain\n\nNo percent here.",
            path: "plain.md"
        ))
        // "%" must be treated as a literal, so only the doc whose title actually
        // contains "%" matches — not every title (which a bare LIKE '%%%' would).
        let results = try await index.search(query: "title:100%")
        #expect(results.map(\.path) == ["coverage.md"])
    }

    @Test("Combined tag: and title: filters intersect")
    func combinedTagAndTitleFilter() async throws {
        let index = try await makeTaggedCorpus()
        // tag:concurrency → {swift-concurrency, rust}; title:swift → {swift-concurrency, swiftui}.
        // Intersection is the single swift-concurrency doc.
        let results = try await index.search(query: "tag:concurrency title:swift")
        #expect(results.map(\.path) == ["swift-concurrency.md"])
    }

    @Test("Re-indexing a document replaces its tags")
    func reindexReplacesTags() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let id = DocumentID()
        try await index.index(document: Document(
            id: id, title: "Note", content: "# Note", path: "note.md", tags: ["old"]
        ))
        try await index.index(document: Document(
            id: id, title: "Note", content: "# Note", path: "note.md", tags: ["new"]
        ))
        #expect(try await index.search(query: "tag:old").isEmpty)
        #expect(try await index.search(query: "tag:new").map(\.path) == ["note.md"])
    }

    @Test("Removing a document drops it from tag filtering")
    func removeDropsTagRows() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let doc = Document(title: "Tagged", content: "# Tagged", path: "tagged.md", tags: ["keep"])
        try await index.index(document: doc)
        #expect(try await index.search(query: "tag:keep").map(\.path) == ["tagged.md"])
        try await index.removeFromIndex(documentID: doc.id)
        #expect(try await index.search(query: "tag:keep").isEmpty)
    }

    @Test("Rebuild refreshes the tag table")
    func rebuildRefreshesTags() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        try await index.index(document: Document(
            title: "Stale", content: "# Stale", path: "stale.md", tags: ["stale"]
        ))
        try await index.rebuildIndex(documents: [
            Document(title: "Fresh", content: "# Fresh", path: "fresh.md", tags: ["fresh"])
        ])
        #expect(try await index.search(query: "tag:stale").isEmpty)
        #expect(try await index.search(query: "tag:fresh").map(\.path) == ["fresh.md"])
    }

    // MARK: - Rebuild progress reporting (PUNK-rwc)

    @Test("rebuildIndex(onProgress:) reports 0...total, ending at total")
    func rebuildReportsProgress() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let docs = (0..<5).map {
            Document(title: "Note \($0)", content: "# Note \($0)", path: "note-\($0).md")
        }

        let recorder = ProgressRecorder<[Int]>()
        try await index.rebuildIndex(documents: docs, onProgress: { completed, total in
            recorder.record([completed, total])
        })

        let reports = recorder.values
        // One priming report (0, total) plus one per indexed doc.
        #expect(reports.count == docs.count + 1)
        #expect(reports.first == [0, 5])
        #expect(reports.last == [5, 5])
        // total stays constant; completed climbs monotonically to total.
        #expect(reports.allSatisfy { $0[1] == 5 })
        #expect(reports.map { $0[0] } == [0, 1, 2, 3, 4, 5])
    }

    @Test("rebuildIndex(onProgress:) on no documents still reports (0, 0)")
    func rebuildEmptyReportsZero() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let recorder = ProgressRecorder<[Int]>()
        try await index.rebuildIndex(documents: [], onProgress: { completed, total in
            recorder.record([completed, total])
        })
        #expect(recorder.values == [[0, 0]])
    }

    @Test("rebuildIndex(onProgress:) actually indexes the documents")
    func rebuildIndexesDocuments() async throws {
        let index = try SQLiteSearchIndex(inMemory: true)
        let docs = [
            Document(title: "Alpha", content: "# Alpha\n\nUnique aardvark token.", path: "alpha.md"),
            Document(title: "Beta", content: "# Beta\n\nUnique bumblebee token.", path: "beta.md"),
        ]
        try await index.rebuildIndex(documents: docs, onProgress: { _, _ in })

        let results = try await index.search(query: "bumblebee")
        #expect(results.first?.title == "Beta")
    }
}
