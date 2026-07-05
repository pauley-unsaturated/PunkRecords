import Foundation

/// Pure derivations for surfacing the *selected note* a chat turn is about.
///
/// One place decides, for a given ``QueryScope`` (+ the current document), whether
/// the turn is focused on a single note and — when it is — what to display and
/// where a tap should navigate. Three surfaces share this logic so they never
/// drift:
/// - the per-message context chip in `ChatBubble` (over a persisted
///   ``MessageContext``),
/// - the composer banner naming the context for the *next* turn, and
/// - the LLM instruction fragment `ContextBuilder` folds into the session prompt
///   so the model knows which note "this"/"the note" refers to.
///
/// Stays pure Core: no SwiftUI, no repository — callers resolve the ``Document``
/// (from the in-memory vault or the repository) and pass it in.
public enum ChatNoteContext {

    /// A note a chat turn refers to, resolved for display and navigation.
    public struct Reference: Equatable, Sendable {
        /// Human-readable note title for the chip / banner label.
        public let title: String
        /// Vault-relative path — the navigation target (set `selectedDocumentPath`).
        public let path: RelativePath

        public init(title: String, path: RelativePath) {
            self.title = title
            self.path = path
        }
    }

    /// The id of the note a scope refers to, or `nil` for vault-wide scopes
    /// (`.global`, `.folder`) which name no single note.
    ///
    /// - `.document(id)` names its embedded id.
    /// - `.selection` names the current document the selection came from.
    public static func referencedNoteID(
        scope: QueryScope,
        currentDocumentID: DocumentID?
    ) -> DocumentID? {
        switch scope {
        case .document(let id): return id
        case .selection: return currentDocumentID
        case .global, .folder: return nil
        }
    }

    /// Display reference for a note-focused scope, given the already-resolved
    /// ``Document``. Returns `nil` when the scope is vault-wide or the note can't
    /// be resolved (e.g. a reloaded thread whose note was since deleted) — in
    /// which case no chip/banner should render.
    public static func reference(
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        document: Document?
    ) -> Reference? {
        guard referencedNoteID(scope: scope, currentDocumentID: currentDocumentID) != nil else {
            return nil
        }
        guard let document else { return nil }
        return Reference(title: document.title, path: document.path)
    }

    /// Convenience over ``reference(scope:currentDocumentID:document:)`` for a
    /// persisted message: reads scope + current-document from its
    /// ``MessageContext``. `document` is that context's `currentDocumentID`
    /// resolved against the *current* vault.
    public static func reference(
        for context: MessageContext?,
        document: Document?
    ) -> Reference? {
        guard let context else { return nil }
        return reference(
            scope: context.scope,
            currentDocumentID: context.currentDocumentID,
            document: document
        )
    }

    /// Instruction fragment naming the selected note for the LLM, or `""` when the
    /// scope is vault-wide / the note is unresolved. Additive to the session
    /// instructions so the model resolves deixis ("this note", "it") to the note
    /// the user has open.
    public static func instructionFragment(
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        document: Document?
    ) -> String {
        guard let ref = reference(
            scope: scope,
            currentDocumentID: currentDocumentID,
            document: document
        ) else {
            return ""
        }
        return "The user currently has the note titled \"\(ref.title)\" (\(ref.path)) "
            + "selected; the conversation refers to it unless stated otherwise."
    }
}
