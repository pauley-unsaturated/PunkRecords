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
}
