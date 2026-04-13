import Foundation

public struct SearchResult: Sendable {
    public let documentID: DocumentID
    public let title: String
    public let path: RelativePath
    public let excerpt: String
    public let score: Float
    public let matchRanges: [Range<String.Index>]

    public init(
        documentID: DocumentID,
        title: String,
        path: RelativePath = "",
        excerpt: String,
        score: Float,
        matchRanges: [Range<String.Index>] = []
    ) {
        self.documentID = documentID
        self.title = title
        self.path = path
        self.excerpt = excerpt
        self.score = score
        self.matchRanges = matchRanges
    }
}

public protocol SearchService: Actor {
    func search(query: String) async throws -> [SearchResult]
    func index(document: Document) async throws
    func removeFromIndex(documentID: DocumentID) async throws
    func rebuildIndex(documents: [Document]) async throws
    func backlinks(for documentID: DocumentID) async throws -> [DocumentID]
}
