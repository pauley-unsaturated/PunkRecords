import Foundation
import Testing
@testable import PunkRecordsCore

/// Pure-logic tests for ``ChatNoteContext`` — the shared decision behind the
/// per-message context chip, the composer banner, and the LLM instruction
/// fragment. No repository / SwiftUI: callers resolve the document and pass it in.
@Suite("ChatNoteContext")
struct ChatNoteContextTests {

    private func makeDocument(
        id: DocumentID = DocumentID(),
        title: String = "Reentrancy Notes",
        path: String = "swift/reentrancy.md"
    ) -> Document {
        Document(id: id, title: title, content: "body", path: path)
    }

    // MARK: - referencedNoteID

    @Test("Document scope names its embedded id")
    func referencedNoteIDForDocumentScope() {
        let id = DocumentID()
        let other = DocumentID()
        #expect(ChatNoteContext.referencedNoteID(scope: .document(id), currentDocumentID: other) == id)
    }

    @Test("Selection scope names the current document")
    func referencedNoteIDForSelectionScope() {
        let current = DocumentID()
        #expect(ChatNoteContext.referencedNoteID(scope: .selection, currentDocumentID: current) == current)
        #expect(ChatNoteContext.referencedNoteID(scope: .selection, currentDocumentID: nil) == nil)
    }

    @Test("Vault-wide scopes name no note")
    func referencedNoteIDForVaultWideScopes() {
        let current = DocumentID()
        #expect(ChatNoteContext.referencedNoteID(scope: .global, currentDocumentID: current) == nil)
        #expect(ChatNoteContext.referencedNoteID(scope: .folder("notes/"), currentDocumentID: current) == nil)
    }

    // MARK: - reference (chip / banner payload)

    @Test("Reference surfaces title + path for a note-focused scope")
    func referenceForDocumentScope() {
        let doc = makeDocument(title: "Actor Reentrancy", path: "swift/actor.md")
        let ref = ChatNoteContext.reference(
            scope: .document(doc.id),
            currentDocumentID: doc.id,
            document: doc
        )
        #expect(ref == ChatNoteContext.Reference(title: "Actor Reentrancy", path: "swift/actor.md"))
    }

    @Test("Reference is nil for vault-wide scope even with a document in hand")
    func referenceNilForGlobalScope() {
        let doc = makeDocument()
        #expect(ChatNoteContext.reference(scope: .global, currentDocumentID: doc.id, document: doc) == nil)
    }

    @Test("Reference is nil when the note can't be resolved (e.g. deleted since)")
    func referenceNilForUnresolvedDocument() {
        let id = DocumentID()
        #expect(ChatNoteContext.reference(scope: .document(id), currentDocumentID: id, document: nil) == nil)
    }

    @Test("Reference from a MessageContext reads its scope + current document")
    func referenceFromMessageContext() {
        let doc = makeDocument(title: "Persisted Note", path: "n/persisted.md")
        let context = MessageContext(
            scope: .document(doc.id),
            scopeLabel: "Document",
            currentDocumentID: doc.id,
            selection: nil,
            variantID: "terse-v1",
            userPrompt: "hi"
        )
        let ref = ChatNoteContext.reference(for: context, document: doc)
        #expect(ref == ChatNoteContext.Reference(title: "Persisted Note", path: "n/persisted.md"))

        // A vault-wide persisted turn yields no chip.
        let globalContext = MessageContext(
            scope: .global,
            scopeLabel: "KB-wide",
            currentDocumentID: doc.id,
            selection: nil,
            variantID: "terse-v1",
            userPrompt: "hi"
        )
        #expect(ChatNoteContext.reference(for: globalContext, document: doc) == nil)
        #expect(ChatNoteContext.reference(for: nil, document: doc) == nil)
    }

    // MARK: - instructionFragment

    @Test("Instruction fragment names the note and its path for note-focused scope")
    func instructionFragmentNamesNote() {
        let doc = makeDocument(title: "Widget Design", path: "design/widget.md")
        let fragment = ChatNoteContext.instructionFragment(
            scope: .document(doc.id),
            currentDocumentID: doc.id,
            document: doc
        )
        #expect(fragment.contains("Widget Design"))
        #expect(fragment.contains("design/widget.md"))
        #expect(fragment.contains("selected"))
        #expect(fragment.contains("refers to it unless stated otherwise"))
    }

    @Test("Instruction fragment is empty for vault-wide scope")
    func instructionFragmentEmptyForGlobalScope() {
        let doc = makeDocument()
        #expect(ChatNoteContext.instructionFragment(scope: .global, currentDocumentID: doc.id, document: doc).isEmpty)
    }

    @Test("Instruction fragment is empty when the note can't be resolved")
    func instructionFragmentEmptyForUnresolvedDocument() {
        let id = DocumentID()
        #expect(ChatNoteContext.instructionFragment(scope: .document(id), currentDocumentID: id, document: nil).isEmpty)
    }
}
