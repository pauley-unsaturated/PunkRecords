import Foundation
import PunkRecordsCore

/// In-memory search service for testing.
public actor MockSearchService: SearchService {
    public var indexedDocuments: [DocumentID: Document] = [:]
    public var searchResults: [SearchResult] = []
    public var queryResultMap: [String: [SearchResult]] = [:]
    public var backlinkMap: [DocumentID: [DocumentID]] = [:]

    public init() {}

    public func search(query: String) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        // Check query-specific results first, fall back to default
        if let queryResults = queryResultMap.first(where: { query.lowercased().contains($0.key.lowercased()) }) {
            return queryResults.value
        }
        return searchResults
    }

    public func index(document: Document) async throws {
        indexedDocuments[document.id] = document
    }

    public func removeFromIndex(documentID: DocumentID) async throws {
        indexedDocuments.removeValue(forKey: documentID)
    }

    public func rebuildIndex(documents: [Document]) async throws {
        indexedDocuments.removeAll()
        for doc in documents {
            indexedDocuments[doc.id] = doc
        }
    }

    public func backlinks(for documentID: DocumentID) async throws -> [DocumentID] {
        backlinkMap[documentID] ?? []
    }

    // MARK: - Test Helpers

    public func setSearchResults(_ results: [SearchResult]) {
        searchResults = results
    }

    public func setQueryResults(_ map: [String: [SearchResult]]) {
        queryResultMap = map
    }

    public func setBacklinkMap(_ map: [DocumentID: [DocumentID]]) {
        backlinkMap = map
    }
}
