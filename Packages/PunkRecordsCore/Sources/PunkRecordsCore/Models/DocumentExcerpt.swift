import Foundation

public struct DocumentExcerpt: Sendable {
    public let documentID: DocumentID
    public let title: String
    public let excerpt: String
    public let relevanceScore: Float

    public init(
        documentID: DocumentID,
        title: String,
        excerpt: String,
        relevanceScore: Float
    ) {
        self.documentID = documentID
        self.title = title
        self.excerpt = excerpt
        self.relevanceScore = relevanceScore
    }
}
