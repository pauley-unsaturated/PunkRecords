import Foundation

/// Pure cosine-similarity ranking over embedding vectors. Embedding-agnostic:
/// callers supply a query vector and candidate vectors (produced by any
/// ``ThreadEmbedder``) and get back the top matches by cosine similarity,
/// tie-broken by id so ordering is deterministic.
public enum ThreadSemanticRanker {

    /// A thread scored by cosine similarity to the query vector.
    public struct ScoredThread: Equatable, Sendable {
        public let id: UUID
        public let score: Double

        public init(id: UUID, score: Double) {
            self.id = id
            self.score = score
        }
    }

    /// Cosine similarity of two equal-length vectors. Returns 0 when the lengths
    /// differ, either is empty, or either has zero magnitude.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Rank candidates by cosine similarity to `query`, highest first. Ties break
    /// by id (descending) for determinism. `limit`, when set, caps the count.
    public static func rank(
        query: [Float],
        candidates: [(id: UUID, vector: [Float])],
        limit: Int? = nil
    ) -> [ScoredThread] {
        guard !query.isEmpty else { return [] }
        var scored = candidates.map {
            ScoredThread(id: $0.id, score: cosineSimilarity(query, $0.vector))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        if let limit, limit >= 0, scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }
}
