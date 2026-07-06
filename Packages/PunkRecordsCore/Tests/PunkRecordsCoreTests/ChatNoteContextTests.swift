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

    // MARK: - focusNote (conversation-level)

    private func context(_ scope: QueryScope, current: DocumentID?) -> MessageContext {
        MessageContext(
            scope: scope,
            scopeLabel: "label",
            currentDocumentID: current,
            selection: nil,
            variantID: "terse-v1",
            userPrompt: "prompt"
        )
    }

    @Test("Focus note is the most recent message with a resolvable note context")
    func focusNoteLatestContextWins() {
        let docA = makeDocument(id: DocumentID(), title: "Note A", path: "a.md")
        let docB = makeDocument(id: DocumentID(), title: "Note B", path: "b.md")
        let messages = [
            ChatMessage(role: .user, content: "about A", context: context(.document(docA.id), current: docA.id)),
            ChatMessage(role: .assistant, content: "reply A"),
            ChatMessage(role: .user, content: "about B", context: context(.document(docB.id), current: docB.id)),
            ChatMessage(role: .assistant, content: "reply B", context: context(.document(docB.id), current: docB.id)),
        ]
        let resolver: (DocumentID) -> Document? = { id in
            [docA.id: docA, docB.id: docB][id]
        }
        #expect(ChatNoteContext.focusNote(for: messages, resolveDocument: resolver)
            == ChatNoteContext.Reference(title: "Note B", path: "b.md"))
    }

    @Test("Focus note is nil when no message carries a note context (all vault-wide)")
    func focusNoteNilWithoutContext() {
        let messages = [
            ChatMessage(role: .user, content: "hi", context: context(.global, current: nil)),
            ChatMessage(role: .assistant, content: "hello"),
        ]
        #expect(ChatNoteContext.focusNote(for: messages) { _ in nil } == nil)
    }

    @Test("Focus note skips an unresolvable latest note, falling back to an older resolvable one")
    func focusNoteSkipsUnresolvable() {
        let docA = makeDocument(id: DocumentID(), title: "Note A", path: "a.md")
        let deletedID = DocumentID()
        let messages = [
            ChatMessage(role: .user, content: "about A", context: context(.document(docA.id), current: docA.id)),
            ChatMessage(role: .user, content: "about a since-deleted note",
                        context: context(.document(deletedID), current: deletedID)),
        ]
        // Only docA resolves; the newest message references a note gone from the vault.
        let resolver: (DocumentID) -> Document? = { $0 == docA.id ? docA : nil }
        #expect(ChatNoteContext.focusNote(for: messages, resolveDocument: resolver)
            == ChatNoteContext.Reference(title: "Note A", path: "a.md"))
    }

    @Test("Focus note is nil when every note context is unresolvable")
    func focusNoteNilWhenAllUnresolvable() {
        let deletedID = DocumentID()
        let messages = [
            ChatMessage(role: .user, content: "x", context: context(.document(deletedID), current: deletedID)),
        ]
        #expect(ChatNoteContext.focusNote(for: messages) { _ in nil } == nil)
    }

    @Test("Focus note from a selection scope resolves the current document")
    func focusNoteSelectionScope() {
        let doc = makeDocument(id: DocumentID(), title: "Selected", path: "sel.md")
        let messages = [
            ChatMessage(role: .user, content: "on selection", context: context(.selection, current: doc.id)),
        ]
        #expect(ChatNoteContext.focusNote(for: messages) { $0 == doc.id ? doc : nil }
            == ChatNoteContext.Reference(title: "Selected", path: "sel.md"))
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
