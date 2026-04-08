import Foundation
import PunkRecordsCore

/// In-memory document repository for testing.
public actor MockDocumentRepository: DocumentRepository {
    public var documents: [DocumentID: Document] = [:]
    private let changesContinuation: AsyncStream<VaultChange>.Continuation
    public let changes: AsyncStream<VaultChange>

    public private(set) var saveCalls: [Document] = []
    public private(set) var deleteCalls: [Document] = []

    public init(documents: [Document] = []) {
        let (stream, continuation) = AsyncStream<VaultChange>.makeStream()
        self.changes = stream
        self.changesContinuation = continuation
        for doc in documents {
            self.documents[doc.id] = doc
        }
    }

    public func document(withID id: DocumentID) async throws -> Document? {
        documents[id]
    }

    public func document(atPath path: RelativePath) async throws -> Document? {
        documents.values.first { $0.path == path }
    }

    public func allDocuments() async throws -> [Document] {
        Array(documents.values)
    }

    public func documentsInFolder(_ path: RelativePath) async throws -> [Document] {
        documents.values.filter { $0.path.hasPrefix(path) }
    }

    public func save(_ document: Document) async throws {
        saveCalls.append(document)
        documents[document.id] = document
        changesContinuation.yield(.added(document))
    }

    public func delete(_ document: Document) async throws {
        deleteCalls.append(document)
        documents.removeValue(forKey: document.id)
        changesContinuation.yield(.deleted(document.id, path: document.path))
    }

    public func move(_ document: Document, to newPath: RelativePath) async throws {
        var moved = document
        moved = Document(
            id: document.id,
            title: document.title,
            content: document.content,
            path: newPath,
            tags: document.tags,
            created: document.created,
            modified: document.modified,
            frontmatter: document.frontmatter,
            linkedDocumentIDs: document.linkedDocumentIDs
        )
        documents[document.id] = moved
    }
}
