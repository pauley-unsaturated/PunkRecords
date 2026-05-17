import Testing
import Foundation
import PunkRecordsCore

@Suite("VaultDocumentsState")
struct VaultDocumentsStateTests {

    private func makeDoc(
        id: DocumentID = DocumentID(),
        title: String = "Note",
        path: RelativePath = "note.md"
    ) -> Document {
        Document(id: id, title: title, content: "# \(title)", path: path)
    }

    // MARK: - upsert: the path-first-then-id rule

    @Test("Upsert appends when neither path nor id matches")
    func upsertAppendsNewDoc() {
        var state = VaultDocumentsState()
        state.upsert(makeDoc(title: "A", path: "a.md"))
        state.upsert(makeDoc(title: "B", path: "b.md"))

        #expect(state.documents.count == 2)
        #expect(state.documents.map(\.title) == ["A", "B"])
    }

    @Test("Upsert replaces by path when path already exists")
    func upsertReplacesByPath() {
        var state = VaultDocumentsState()
        let original = makeDoc(title: "Original", path: "shared.md")
        state.upsert(original)

        // Note: same path, different id, new title. Path wins.
        let updated = makeDoc(id: DocumentID(), title: "Updated", path: "shared.md")
        state.upsert(updated)

        #expect(state.documents.count == 1)
        #expect(state.documents.first?.title == "Updated")
        #expect(state.documents.first?.id == updated.id)
    }

    @Test("Upsert falls back to id when path is new but id matches")
    func upsertFallsBackToID() {
        // The intended use: an external rename emits .deleted(old) + .added(new). If
        // the .deleted is lost or arrives late, the .added still finds the row by id
        // and updates it in place, so the list never grows phantom duplicates.
        var state = VaultDocumentsState()
        let id = DocumentID()
        state.upsert(makeDoc(id: id, title: "Old", path: "old.md"))
        state.upsert(makeDoc(id: id, title: "New", path: "new.md"))

        #expect(state.documents.count == 1)
        #expect(state.documents.first?.path == "new.md")
    }

    @Test("Duplicate frontmatter ids collapse — PUNK-kdm heals them at vault open")
    func upsertDuplicateIDCollapses() {
        // Path-first + id-fallback inevitably collapses two paths that share an id,
        // because the id fallback exists to support rename. The user-facing fix is
        // PUNK-kdm: FileSystemDocumentRepository.healDuplicateIDs() rewrites one of
        // the colliding files with a fresh id before this state is ever loaded, so
        // the collapse can't happen in practice.
        var state = VaultDocumentsState()
        let sharedID = DocumentID()
        state.upsert(makeDoc(id: sharedID, title: "First", path: "first.md"))
        state.upsert(makeDoc(id: sharedID, title: "Second", path: "second.md"))

        #expect(state.documents.count == 1)
        #expect(state.documents.first?.path == "second.md",
                "Second upsert matches by id and replaces in place")
    }

    // MARK: - remove + selection bookkeeping

    @Test("Remove clears selection when it pointed at the removed path")
    func removeClearsSelection() {
        var state = VaultDocumentsState(
            documents: [makeDoc(title: "A", path: "a.md"), makeDoc(title: "B", path: "b.md")],
            selectedPath: "a.md"
        )
        state.remove(path: "a.md")
        #expect(state.documents.map(\.path) == ["b.md"])
        #expect(state.selectedPath == nil)
    }

    @Test("Remove preserves selection when it points elsewhere")
    func removeKeepsUnrelatedSelection() {
        var state = VaultDocumentsState(
            documents: [makeDoc(title: "A", path: "a.md"), makeDoc(title: "B", path: "b.md")],
            selectedPath: "b.md"
        )
        state.remove(path: "a.md")
        #expect(state.selectedPath == "b.md")
    }

    // MARK: - applyRename + selection-follows-rename

    @Test("applyRename follows the selection to the new path")
    func renameFollowsSelection() {
        let doc = makeDoc(title: "Original", path: "original.md")
        var state = VaultDocumentsState(documents: [doc], selectedPath: doc.path)

        let renamed = Document(
            id: doc.id, title: "Renamed",
            content: "# Renamed", path: "renamed.md"
        )
        state.applyRename(from: doc.path, to: renamed)

        #expect(state.documents.count == 1)
        #expect(state.documents.first?.path == "renamed.md")
        #expect(state.selectedPath == "renamed.md")
    }

    @Test("applyRename leaves selection alone when a different doc is selected")
    func renameUnrelatedKeepsSelection() {
        let a = makeDoc(title: "A", path: "a.md")
        let b = makeDoc(title: "B", path: "b.md")
        var state = VaultDocumentsState(documents: [a, b], selectedPath: "b.md")

        let renamedA = Document(id: a.id, title: "A renamed", content: "", path: "a-renamed.md")
        state.applyRename(from: a.path, to: renamedA)

        #expect(state.selectedPath == "b.md")
        #expect(Set(state.documents.map(\.path)) == ["a-renamed.md", "b.md"])
    }

    @Test("applyRename with same path is a content-only update")
    func renameInPlace() {
        let doc = makeDoc(title: "A", path: "a.md")
        var state = VaultDocumentsState(documents: [doc], selectedPath: doc.path)

        let updated = Document(id: doc.id, title: "A v2", content: "# A v2", path: "a.md")
        state.applyRename(from: doc.path, to: updated)

        #expect(state.documents.count == 1)
        #expect(state.documents.first?.title == "A v2")
        #expect(state.selectedPath == "a.md")
    }

    // MARK: - apply(VaultChange)

    @Test("apply(.added) inserts a new document")
    func applyAdded() {
        var state = VaultDocumentsState()
        let doc = makeDoc(title: "New", path: "new.md")
        state.apply(.added(doc))
        #expect(state.documents.count == 1)
        #expect(state.documents.first?.path == "new.md")
    }

    @Test("apply(.modified) updates an existing document")
    func applyModified() {
        let doc = makeDoc(title: "v1", path: "n.md")
        var state = VaultDocumentsState(documents: [doc])
        let updated = Document(id: doc.id, title: "v2", content: "", path: "n.md")
        state.apply(.modified(updated))
        #expect(state.documents.first?.title == "v2")
    }

    @Test("apply(.deleted) drops by path and clears matching selection")
    func applyDeleted() {
        let doc = makeDoc(title: "X", path: "x.md")
        var state = VaultDocumentsState(documents: [doc], selectedPath: "x.md")
        state.apply(.deleted(doc.id, path: "x.md"))
        #expect(state.documents.isEmpty)
        #expect(state.selectedPath == nil)
    }

    // MARK: - selectedDocument lookup

    @Test("selectedDocument resolves by path")
    func selectedDocumentLookup() {
        let a = makeDoc(title: "A", path: "a.md")
        let b = makeDoc(title: "B", path: "b.md")
        let state = VaultDocumentsState(documents: [a, b], selectedPath: "b.md")
        #expect(state.selectedDocument?.title == "B")
    }

    @Test("selectedDocument is nil when path doesn't match any document")
    func selectedDocumentMismatchIsNil() {
        let a = makeDoc(title: "A", path: "a.md")
        let state = VaultDocumentsState(documents: [a], selectedPath: "missing.md")
        #expect(state.selectedDocument == nil)
    }

    // MARK: - the eager-upsert createNewNote scenario

    @Test("Eager upsert + selection mirrors AppState.createNewNote")
    func eagerCreateThenWatchEventCoalesces() {
        // Simulates: createNewNote eagerly inserts the doc and selects it; later, the
        // FS watcher emits .added for the same file. The list should not double-count.
        var state = VaultDocumentsState()
        let doc = makeDoc(title: "Untitled", path: "Untitled.md")

        state.upsert(doc)
        state.selectedPath = doc.path
        #expect(state.documents.count == 1)
        #expect(state.selectedPath == "Untitled.md")

        // The watcher reports the same file moments later.
        state.apply(.added(doc))
        #expect(state.documents.count == 1, "Watcher event must not duplicate the eager insert")
        #expect(state.selectedPath == "Untitled.md")
    }
}
