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

    // MARK: - Duplicate ID Healing

    /// Helper: write a file with a fixed UUID in its frontmatter so we can construct
    /// a deliberate collision on disk.
    private func writeFile(
        sharedID: UUID,
        title: String,
        path: String,
        in vaultRoot: URL
    ) throws {
        let content = """
            ---
            id: \(sharedID.uuidString)
            ---

            # \(title)
            """
        let url = vaultRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("healDuplicateIDs rewrites the duplicate, keeps the alphabetically-first path")
    func healingPicksStableWinner() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)

        let shared = UUID()
        try writeFile(sharedID: shared, title: "AKB", path: "AgentKontrol-KB.md", in: vault.rootURL)
        try writeFile(sharedID: shared, title: "Untitled", path: "Untitled.md", in: vault.rootURL)

        let healed = try await repo.healDuplicateIDs()

        #expect(healed.count == 1)
        // Sorted lexicographically, "AgentKontrol-KB.md" < "Untitled.md", so the
        // Untitled file is the victim.
        #expect(healed.first?.path == "Untitled.md")
        #expect(healed.first?.oldID == shared)
        #expect(healed.first?.newID != shared)

        // The kept file still has the original id.
        let kept = try await repo.document(atPath: "AgentKontrol-KB.md")
        #expect(kept?.id == shared)

        // The healed file now has a fresh id.
        let rewritten = try await repo.document(atPath: "Untitled.md")
        #expect(rewritten?.id != shared)
        #expect(rewritten?.id == healed.first?.newID)
    }

    @Test("healDuplicateIDs is a no-op on a clean vault")
    func healingNoOpOnCleanVault() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)

        try writeFile(sharedID: UUID(), title: "A", path: "a.md", in: vault.rootURL)
        try writeFile(sharedID: UUID(), title: "B", path: "b.md", in: vault.rootURL)

        let healed = try await repo.healDuplicateIDs()
        #expect(healed.isEmpty)
    }

    @Test("healDuplicateIDs handles three-way collision")
    func healingThreeWayCollision() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)

        let shared = UUID()
        try writeFile(sharedID: shared, title: "A", path: "a.md", in: vault.rootURL)
        try writeFile(sharedID: shared, title: "B", path: "b.md", in: vault.rootURL)
        try writeFile(sharedID: shared, title: "C", path: "c.md", in: vault.rootURL)

        let healed = try await repo.healDuplicateIDs()
        #expect(healed.count == 2)
        #expect(healed.map(\.path).sorted() == ["b.md", "c.md"])

        // After healing, all three should have distinct ids.
        let all = try await repo.allDocuments()
        let ids = Set(all.map(\.id))
        #expect(ids.count == 3)
    }

    @Test("rewriteFrontmatterID leaves body intact when the UUID appears in body text")
    func rewriteOnlyTouchesFrontmatter() {
        let id = UUID()
        let other = UUID()
        let content = """
            ---
            id: \(id.uuidString)
            ---

            # Note

            Earlier referenced \(id.uuidString) in the prose.
            """

        let rewritten = FileSystemDocumentRepository.rewriteFrontmatterID(
            in: content,
            oldID: id,
            newID: other
        )

        #expect(rewritten != nil)
        // The body mention should not be substituted.
        let bodyOccurrences = (rewritten ?? "").components(separatedBy: id.uuidString).count - 1
        #expect(bodyOccurrences == 1, "Body mention of the old UUID must be preserved")
        let newOccurrences = (rewritten ?? "").components(separatedBy: other.uuidString).count - 1
        #expect(newOccurrences == 1, "New UUID should appear exactly once (in frontmatter)")
    }
}
