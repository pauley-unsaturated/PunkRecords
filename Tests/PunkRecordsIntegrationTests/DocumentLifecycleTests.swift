import Testing
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

@Suite("Document Lifecycle Integration Tests")
struct DocumentLifecycleTests {

    private func makeTempVault() throws -> (vault: Vault, repo: FileSystemDocumentRepository, index: SQLiteSearchIndex, cleanup: @Sendable () -> Void) {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        return (vault, repo, index, cleanup)
    }

    /// Creates a Document with frontmatter containing its ID so the repo round-trips correctly.
    private func makeDocument(
        title: String,
        body: String,
        path: String,
        tags: [String] = [],
        linkedDocumentIDs: [DocumentID] = []
    ) -> Document {
        let id = DocumentID()
        let parser = MarkdownParser()
        let frontmatter = parser.generateFrontmatter(id: id, tags: tags)
        let content = frontmatter + "\n\n# \(title)\n\n\(body)"
        return Document(
            id: id,
            title: title,
            content: content,
            path: path,
            tags: tags,
            linkedDocumentIDs: linkedDocumentIDs
        )
    }

    @Test("Create vault, write documents, and search")
    func createAndSearch() async throws {
        let (_, repo, index, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc = makeDocument(
            title: "Test Note",
            body: "This is about Swift programming.",
            path: "test-note.md",
            tags: ["swift"]
        )
        try await repo.save(doc)
        try await index.index(document: doc)

        let results = try await index.search(query: "Swift programming")
        #expect(!results.isEmpty)
        #expect(results.first?.documentID == doc.id)
    }

    @Test("Save and retrieve document by ID")
    func saveAndRetrieveByID() async throws {
        let (_, repo, _, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc = makeDocument(
            title: "Retrieve Me",
            body: "Content here.",
            path: "retrieve.md"
        )
        try await repo.save(doc)

        let retrieved = try await repo.document(withID: doc.id)
        #expect(retrieved != nil)
        #expect(retrieved?.title == "Retrieve Me")
    }

    @Test("Delete removes document from disk and index")
    func deleteDocument() async throws {
        let (_, repo, index, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc = makeDocument(
            title: "To Delete",
            body: "Will be removed.",
            path: "delete-me.md"
        )
        try await repo.save(doc)
        try await index.index(document: doc)

        try await repo.delete(doc)
        try await index.removeFromIndex(documentID: doc.id)

        let retrieved = try await repo.document(withID: doc.id)
        #expect(retrieved == nil)

        let results = try await index.search(query: "Delete")
        #expect(results.isEmpty)
    }

    @Test("Move document updates path")
    func moveDocument() async throws {
        let (_, repo, _, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc = makeDocument(
            title: "Movable",
            body: "Will be moved.",
            path: "movable.md"
        )
        try await repo.save(doc)

        try await repo.move(doc, to: "subfolder/movable.md")

        let all = try await repo.allDocuments()
        let moved = all.first { $0.id == doc.id }
        #expect(moved != nil, "Document not found after move. All paths: \(all.map(\.path))")
        #expect(moved?.path == "subfolder/movable.md")
    }

    @Test("Rebuild index re-indexes all documents")
    func rebuildIndex() async throws {
        let (_, repo, index, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc1 = makeDocument(
            title: "First",
            body: "Alpha content.",
            path: "first.md"
        )
        let doc2 = makeDocument(
            title: "Second",
            body: "Beta content.",
            path: "second.md"
        )
        try await repo.save(doc1)
        try await repo.save(doc2)

        try await index.rebuildIndex(documents: [doc1, doc2])

        let alphaResults = try await index.search(query: "Alpha")
        #expect(!alphaResults.isEmpty)
        #expect(alphaResults.first?.documentID == doc1.id)

        let betaResults = try await index.search(query: "Beta")
        #expect(!betaResults.isEmpty)
        #expect(betaResults.first?.documentID == doc2.id)
    }

    @Test("Backlinks track document references")
    func backlinksTracking() async throws {
        let (_, repo, index, cleanup) = try makeTempVault()
        defer { cleanup() }

        let target = makeDocument(
            title: "Target Note",
            body: "I am referenced.",
            path: "target.md"
        )

        let source = makeDocument(
            title: "Source Note",
            body: "See [[Target Note]].",
            path: "source.md",
            linkedDocumentIDs: [target.id]
        )

        try await repo.save(target)
        try await repo.save(source)
        try await index.index(document: target)
        try await index.index(document: source)

        let backlinks = try await index.backlinks(for: target.id)
        #expect(backlinks.contains(source.id))
    }

    @Test("Multiple documents in subfolder are all discoverable")
    func subfolderDocuments() async throws {
        let (_, repo, _, cleanup) = try makeTempVault()
        defer { cleanup() }

        let doc1 = makeDocument(
            title: "Sub A",
            body: "Content A.",
            path: "projects/a.md"
        )
        let doc2 = makeDocument(
            title: "Sub B",
            body: "Content B.",
            path: "projects/b.md"
        )
        try await repo.save(doc1)
        try await repo.save(doc2)

        let all = try await repo.allDocuments()
        let projectDocs = all.filter { $0.path.hasPrefix("projects/") }
        #expect(projectDocs.count == 2, "Expected 2 project docs. All paths: \(all.map(\.path))")
    }
}
