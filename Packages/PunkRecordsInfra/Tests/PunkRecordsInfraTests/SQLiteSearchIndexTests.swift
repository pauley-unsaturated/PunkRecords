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
}
