import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// Covers the file-level operations that back AppState's createNewNote / renameDocument /
/// deleteDocument. AppState itself lives in the app target (out of reach from this bundle),
/// so we exercise the same sequences directly against FileSystemDocumentRepository.
@Suite("Vault File Operations Integration Tests")
struct VaultFileOperationsTests {

    private func makeVault() throws -> (repo: FileSystemDocumentRepository, index: SQLiteSearchIndex, cleanup: @Sendable () -> Void) {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        return (repo, index, cleanup)
    }

    private func makeUntitled(id: DocumentID = DocumentID(), path: String = "Untitled.md") -> Document {
        let parser = MarkdownParser()
        let frontmatter = parser.generateFrontmatter(id: id)
        let content = frontmatter + "\n\n# Untitled\n\n"
        return Document(id: id, title: "Untitled", content: content, path: path)
    }

    // MARK: - uniqueNotePath against a real repo

    @Test("uniqueNotePath returns base when nothing exists")
    func uniquePathEmptyVault() async throws {
        let (repo, _, cleanup) = try makeVault()
        defer { cleanup() }

        let path = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { candidate in
            (try? await repo.document(atPath: candidate)) != nil
        }
        #expect(path == "Untitled.md")
    }

    @Test("uniqueNotePath bumps to '2' when Untitled.md exists")
    func uniquePathBumpsOnce() async throws {
        let (repo, _, cleanup) = try makeVault()
        defer { cleanup() }

        try await repo.save(makeUntitled())

        let path = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { candidate in
            (try? await repo.document(atPath: candidate)) != nil
        }
        #expect(path == "Untitled 2.md")
    }

    @Test("uniqueNotePath keeps bumping past consecutive collisions")
    func uniquePathBumpsRepeatedly() async throws {
        let (repo, _, cleanup) = try makeVault()
        defer { cleanup() }

        try await repo.save(makeUntitled(path: "Untitled.md"))
        try await repo.save(makeUntitled(path: "Untitled 2.md"))
        try await repo.save(makeUntitled(path: "Untitled 3.md"))

        let path = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { candidate in
            (try? await repo.document(atPath: candidate)) != nil
        }
        #expect(path == "Untitled 4.md")
    }

    // MARK: - Rename flow (save-new + delete-old)

    @Test("Renaming a doc moves the file on disk and rewrites the H1")
    func renameMovesFileAndUpdatesH1() async throws {
        let (repo, index, cleanup) = try makeVault()
        defer { cleanup() }

        let original = makeUntitled()
        try await repo.save(original)
        try await index.index(document: original)

        // Mimic AppState.renameDocument: build updated doc, save to new path, delete old.
        let newTitle = "Mark's Backlog"
        let newPath = "\(FilenameHelpers.sanitizeFilename(newTitle)).md"
        let updatedContent = FilenameHelpers.replaceFirstH1(in: original.content, with: newTitle)
        let renamed = Document(
            id: original.id,
            title: newTitle,
            content: updatedContent,
            path: newPath
        )
        try await repo.save(renamed)
        try await repo.delete(original)
        try await index.index(document: renamed)

        let movedBack = try await repo.document(atPath: newPath)
        let originalGone = try await repo.document(atPath: original.path)
        #expect(movedBack != nil)
        #expect(originalGone == nil)
        #expect(movedBack?.content.contains("# Mark's Backlog") == true)
        #expect(movedBack?.content.contains("# Untitled") == false)
    }

    @Test("Rename collision is detectable before overwrite")
    func renameDetectsCollision() async throws {
        let (repo, _, cleanup) = try makeVault()
        defer { cleanup() }

        let source = makeUntitled(path: "Untitled.md")
        let blocker = makeUntitled(id: DocumentID(), path: "Mark's Backlog.md")
        try await repo.save(source)
        try await repo.save(blocker)

        let intendedNewPath = "Mark's Backlog.md"
        let collision = try await repo.document(atPath: intendedNewPath)
        #expect(collision != nil)
        // AppState's renameDocument would short-circuit here with an error message.
    }

    // MARK: - Delete flow

    @Test("Deleting a doc removes the file and clears the search index entry")
    func deleteRemovesFileAndIndex() async throws {
        let (repo, index, cleanup) = try makeVault()
        defer { cleanup() }

        let doc = makeUntitled()
        try await repo.save(doc)
        try await index.index(document: doc)

        try await repo.delete(doc)
        try await index.removeFromIndex(documentID: doc.id)

        let gone = try await repo.document(atPath: doc.path)
        #expect(gone == nil)

        let hits = try await index.search(query: "Untitled")
        #expect(hits.allSatisfy { $0.documentID != doc.id })
    }
}
