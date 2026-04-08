import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

@Suite("FileSystemDocumentRepository")
struct FileSystemDocumentRepositoryTests {
    let factory = TempVaultFactory()

    private func makeRepo() throws -> (FileSystemDocumentRepository, @Sendable () -> Void) {
        let (vault, cleanup) = try factory.createTempVault()
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        return (repo, cleanup)
    }

    private func makeDocument(
        title: String = "Test Note",
        path: RelativePath = "test-note.md",
        tags: [String] = []
    ) -> Document {
        let id = UUID()
        let content = """
            ---
            id: \(id.uuidString)
            tags: [\(tags.joined(separator: ", "))]
            ---

            # \(title)

            Some content here.
            """
        return Document(
            id: id,
            title: title,
            content: content,
            path: path,
            tags: tags
        )
    }

    // MARK: - Tests

    @Test("save then document(atPath:) round-trip")
    func saveAndRetrieveByPath() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc = makeDocument(title: "Round Trip", path: "notes/round-trip.md")
        try await repo.save(doc)

        let retrieved = try await repo.document(atPath: "notes/round-trip.md")
        #expect(retrieved != nil)
        #expect(retrieved?.title == "Round Trip")
        #expect(retrieved?.path == "notes/round-trip.md")
    }

    @Test("save then document(withID:) lookup")
    func saveAndRetrieveByID() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc = makeDocument(title: "By ID", path: "by-id.md")
        try await repo.save(doc)

        let retrieved = try await repo.document(withID: doc.id)
        #expect(retrieved != nil)
        #expect(retrieved?.id == doc.id)
        #expect(retrieved?.title == "By ID")
    }

    @Test("allDocuments lists all saved docs")
    func allDocumentsListsAll() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc1 = makeDocument(title: "First", path: "first.md")
        let doc2 = makeDocument(title: "Second", path: "second.md")
        let doc3 = makeDocument(title: "Third", path: "subfolder/third.md")

        try await repo.save(doc1)
        try await repo.save(doc2)
        try await repo.save(doc3)

        let all = try await repo.allDocuments()
        #expect(all.count == 3)

        let titles = Set(all.map(\.title))
        #expect(titles.contains("First"))
        #expect(titles.contains("Second"))
        #expect(titles.contains("Third"))
    }

    @Test("documentsInFolder filters correctly")
    func documentsInFolderFilters() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let rootDoc = makeDocument(title: "Root", path: "root.md")
        let folderDoc1 = makeDocument(title: "In Folder A", path: "folderA/note1.md")
        let folderDoc2 = makeDocument(title: "Also In Folder A", path: "folderA/note2.md")
        let otherDoc = makeDocument(title: "In Folder B", path: "folderB/note.md")

        try await repo.save(rootDoc)
        try await repo.save(folderDoc1)
        try await repo.save(folderDoc2)
        try await repo.save(otherDoc)

        let folderADocs = try await repo.documentsInFolder("folderA")
        #expect(folderADocs.count == 2)

        let titles = Set(folderADocs.map(\.title))
        #expect(titles.contains("In Folder A"))
        #expect(titles.contains("Also In Folder A"))
    }

    @Test("delete removes document")
    func deleteRemovesDocument() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc = makeDocument(title: "Doomed", path: "doomed.md")
        try await repo.save(doc)

        // Verify it exists
        let before = try await repo.document(atPath: "doomed.md")
        #expect(before != nil)

        try await repo.delete(doc)

        let after = try await repo.document(atPath: "doomed.md")
        #expect(after == nil)
    }

    @Test("move relocates document")
    func moveRelocatesDocument() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc = makeDocument(title: "Movable", path: "original.md")
        try await repo.save(doc)

        try await repo.move(doc, to: "archive/moved.md")

        let atOld = try await repo.document(atPath: "original.md")
        #expect(atOld == nil)

        let atNew = try await repo.document(atPath: "archive/moved.md")
        #expect(atNew != nil)
        #expect(atNew?.title == "Movable")
    }

    @Test("save creates intermediate directories")
    func saveCreatesIntermediateDirectories() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let doc = makeDocument(title: "Deep", path: "a/b/c/deep-note.md")
        try await repo.save(doc)

        let retrieved = try await repo.document(atPath: "a/b/c/deep-note.md")
        #expect(retrieved != nil)
        #expect(retrieved?.title == "Deep")
    }

    @Test("empty vault returns empty allDocuments")
    func emptyVaultReturnsEmpty() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let all = try await repo.allDocuments()
        #expect(all.isEmpty)
    }
}
