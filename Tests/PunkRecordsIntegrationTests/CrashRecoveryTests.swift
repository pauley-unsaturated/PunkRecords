import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// End-to-end crash-recovery behavior over a real temp vault: sidecars written
/// for unsaved edits, removed after a durable save, and surfaced (with restored
/// content) by the launch scan. The scheduling + classification decisions are
/// unit-tested in Core (`AutosaveSchedulerTests`, `RecoveryScanTests`); these
/// integration tests exercise the `FileSystemCrashRecoveryStore` I/O and the
/// scan-then-restore flow the app performs on open.
@Suite("Crash recovery — sidecar lifecycle over a temp vault")
struct CrashRecoveryTests {
    let factory = TempVaultFactory()

    private func noteContent(id: UUID, body: String) -> String {
        """
        ---
        id: \(id.uuidString)
        tags: []
        ---

        # Note

        \(body)
        """
    }

    @Test("Sidecar written for unsaved changes is discoverable with its content")
    func sidecarWrittenForUnsavedChanges() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemCrashRecoveryStore(vaultRoot: vault.rootURL)

        let id = UUID()
        try await store.writeSidecar(noteID: id, content: "in-progress edit")

        // The physical sidecar lands at the conventional path…
        let expected = vault.rootURL
            .appendingPathComponent(VaultPaths.recoverySidecarPath(forNoteID: id))
        #expect(FileManager.default.fileExists(atPath: expected.path))

        // …and loadSidecars reads it back intact.
        let sidecars = try await store.loadSidecars()
        #expect(sidecars.count == 1)
        #expect(sidecars.first?.noteID == id)
        #expect(sidecars.first?.content == "in-progress edit")
    }

    @Test("Sidecar is removed after a real save")
    func sidecarRemovedAfterSave() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let store = FileSystemCrashRecoveryStore(vaultRoot: vault.rootURL)

        let id = UUID()
        // Simulate the editor: unsaved edit → sidecar exists.
        try await store.writeSidecar(noteID: id, content: "typed but not saved")
        #expect(try await store.loadSidecars().count == 1)

        // Real save lands the content in the note, then drops the sidecar.
        let doc = Document(id: id, title: "Note", content: noteContent(id: id, body: "typed but not saved"), path: "note.md")
        try await repo.save(doc)
        try await store.removeSidecar(noteID: id)

        #expect(try await store.loadSidecars().isEmpty)
    }

    @Test("Launch scan finds a newer sidecar and restores its content")
    func scanFindsNewerSidecarAndRestores() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let store = FileSystemCrashRecoveryStore(vaultRoot: vault.rootURL)

        let id = UUID()
        // 1. A note is on disk with the last durably-saved body.
        let saved = Document(id: id, title: "Note", content: noteContent(id: id, body: "saved body"), path: "note.md")
        try await repo.save(saved)

        // 2. A crash left a sidecar with newer, unsaved content.
        let recoveredContent = noteContent(id: id, body: "UNSAVED body from before the crash")
        try await store.writeSidecar(noteID: id, content: recoveredContent)

        // Backdate the note file so the sidecar is unambiguously newer than it,
        // independent of filesystem timestamp granularity.
        let noteURL = vault.rootURL.appendingPathComponent("note.md")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: noteURL.path
        )

        // 3. The launch scan: gather note state + sidecars, classify.
        let onDisk = try await repo.document(withID: id)
        #expect(onDisk != nil)
        let notes = [id: RecoveryNoteState(content: onDisk!.content, modified: onDisk!.modified)]
        let sidecars = try await store.loadSidecars()
        let result = RecoveryScan.scan(sidecars: sidecars, notes: notes)

        #expect(result.stale.isEmpty)
        #expect(result.recoverable.count == 1)
        let candidate = try #require(result.recoverable.first)
        #expect(candidate.noteID == id)
        #expect(candidate.recoveredContent == recoveredContent)

        // 4. Accepting recovery restores the content into the note and drops
        //    the sidecar.
        let restored = Document(id: id, title: "Note", content: candidate.recoveredContent, path: "note.md")
        try await repo.save(restored)
        try await store.removeSidecar(noteID: id)

        let reread = try await repo.document(withID: id)
        #expect(reread?.content.contains("UNSAVED body from before the crash") == true)
        #expect(try await store.loadSidecars().isEmpty)
    }

    @Test("An already-saved sidecar scans as stale (no prompt)")
    func matchingSidecarIsStale() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let store = FileSystemCrashRecoveryStore(vaultRoot: vault.rootURL)

        let id = UUID()
        let body = noteContent(id: id, body: "same on disk and in sidecar")
        try await repo.save(Document(id: id, title: "Note", content: body, path: "note.md"))
        try await store.writeSidecar(noteID: id, content: body)

        let onDisk = try #require(try await repo.document(withID: id))
        let notes = [id: RecoveryNoteState(content: onDisk.content, modified: onDisk.modified)]
        let result = RecoveryScan.scan(sidecars: try await store.loadSidecars(), notes: notes)

        #expect(result.recoverable.isEmpty)
        #expect(result.stale == [id])
    }
}
