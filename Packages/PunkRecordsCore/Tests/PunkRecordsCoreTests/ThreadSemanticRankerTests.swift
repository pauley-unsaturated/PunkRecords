import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("ThreadSemanticRanker — cosine ranking over embedding vectors")
struct ThreadSemanticRankerTests {

    @Test("Cosine similarity: identical, orthogonal, opposite, degenerate")
    func cosineBasics() {
        #expect(abs(ThreadSemanticRanker.cosineSimilarity([1, 2, 3], [1, 2, 3]) - 1.0) < 1e-9)
        #expect(abs(ThreadSemanticRanker.cosineSimilarity([1, 0], [0, 1]) - 0.0) < 1e-9)
        #expect(abs(ThreadSemanticRanker.cosineSimilarity([1, 0], [-1, 0]) - (-1.0)) < 1e-9)
        // Mismatched length and zero-magnitude both return 0.
        #expect(ThreadSemanticRanker.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
        #expect(ThreadSemanticRanker.cosineSimilarity([0, 0], [1, 1]) == 0)
        #expect(ThreadSemanticRanker.cosineSimilarity([], []) == 0)
    }

    @Test("Ranks candidates by cosine similarity, highest first")
    func ranksBySimilarity() {
        let near = UUID()
        let mid = UUID()
        let far = UUID()
        let ranked = ThreadSemanticRanker.rank(
            query: [1, 0],
            candidates: [
                (id: far, vector: [0, 1]),      // cosine 0
                (id: near, vector: [1, 0]),     // cosine 1
                (id: mid, vector: [1, 1]),      // cosine ~0.707
            ]
        )
        #expect(ranked.map(\.id) == [near, mid, far])
        #expect(abs((ranked.first?.score ?? 0) - 1.0) < 1e-9)
    }

    @Test("Top-k limit caps results after sorting")
    func topKLimit() {
        let ids = (0..<4).map { _ in UUID() }
        let candidates = zip(ids, [[1, 0], [0.9, 0.1], [0.5, 0.5], [0, 1]] as [[Float]])
            .map { (id: $0, vector: $1) }
        let ranked = ThreadSemanticRanker.rank(query: [1, 0], candidates: candidates, limit: 2)
        #expect(ranked.count == 2)
        #expect(ranked.first?.id == ids[0])
    }

    @Test("Equal scores break ties by id descending, deterministically")
    func tieBreakDeterministic() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let forward = ThreadSemanticRanker.rank(
            query: [1, 0],
            candidates: [(id: low, vector: [1, 0]), (id: high, vector: [1, 0])]
        )
        let reverse = ThreadSemanticRanker.rank(
            query: [1, 0],
            candidates: [(id: high, vector: [1, 0]), (id: low, vector: [1, 0])]
        )
        #expect(forward == reverse)
        #expect(forward.first?.id == high)
    }

    @Test("Empty query vector yields no ranking")
    func emptyQuery() {
        #expect(ThreadSemanticRanker.rank(query: [], candidates: [(id: UUID(), vector: [1, 0])]).isEmpty)
    }
}
