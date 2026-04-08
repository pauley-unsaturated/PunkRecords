import Foundation

public protocol DocumentRepository: Actor {
    func document(withID id: DocumentID) async throws -> Document?
    func document(atPath path: RelativePath) async throws -> Document?
    func allDocuments() async throws -> [Document]
    func documentsInFolder(_ path: RelativePath) async throws -> [Document]

    func save(_ document: Document) async throws
    func delete(_ document: Document) async throws
    func move(_ document: Document, to newPath: RelativePath) async throws

    var changes: AsyncStream<VaultChange> { get }
}
