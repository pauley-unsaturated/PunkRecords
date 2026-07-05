import Foundation

/// Snapshot of the context surrounding a chat message, captured at submission
/// time. Attached to ``ChatMessage`` so "Report Issue" can later reconstruct
/// what the user did.
public struct MessageContext: Sendable, Codable, Equatable {
    public let scope: QueryScope
    public let scopeLabel: String
    public let currentDocumentID: DocumentID?
    public let selection: String?
    public let variantID: String
    public let userPrompt: String

    public init(
        scope: QueryScope,
        scopeLabel: String,
        currentDocumentID: DocumentID?,
        selection: String?,
        variantID: String,
        userPrompt: String
    ) {
        self.scope = scope
        self.scopeLabel = scopeLabel
        self.currentDocumentID = currentDocumentID
        self.selection = selection
        self.variantID = variantID
        self.userPrompt = userPrompt
    }
}
