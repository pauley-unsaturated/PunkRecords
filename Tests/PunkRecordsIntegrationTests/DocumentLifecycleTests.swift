import Testing
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

@Suite("Document Lifecycle Integration Tests")
struct DocumentLifecycleTests {
    @Test("Create vault, write documents, and search")
    func createAndSearch() async throws {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }

        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)

        // Write a document
        let doc = Document(
            title: "Test Note",
            content: "# Test Note\n\nThis is about Swift programming.",
            path: "test-note.md",
            tags: ["swift"]
        )
        try await repo.save(doc)
        try await index.index(document: doc)

        // Search should find it
        let results = try await index.search(query: "Swift programming")
        #expect(!results.isEmpty)
        #expect(results.first?.documentID == doc.id)
    }
}
