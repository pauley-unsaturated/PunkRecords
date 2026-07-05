import Foundation

/// Deterministic keyword ranking over chat threads. Given each candidate's
/// searchable text (typically title + rendered transcript), it scores threads by
/// how many query-term occurrences they contain — case-insensitive, simple term
/// frequency — and returns matches ordered by score, breaking ties by recency
/// (`updatedAt` desc) then id so results are stable across runs and process
/// launches.
///
/// Pure Core logic: the tool loads thread text and hands it here; the ranker
/// never touches the store or the filesystem.
public enum ThreadKeywordRanker {

    /// A thread that matched the query, with its term-frequency score.
    public struct ScoredThread: Equatable, Sendable {
        public let summary: ThreadSummary
        public let score: Int

        public init(summary: ThreadSummary, score: Int) {
            self.summary = summary
            self.score = score
        }
    }

    /// Split text into lowercased alphanumeric terms.
    static func terms(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Rank candidates against a query. Only threads with at least one term hit
    /// are returned. `limit`, when set, caps the result count after sorting.
    public static func rank(
        query: String,
        candidates: [(summary: ThreadSummary, text: String)],
        limit: Int? = nil
    ) -> [ScoredThread] {
        let queryTerms = Set(terms(in: query))
        guard !queryTerms.isEmpty else { return [] }

        var scored: [ScoredThread] = []
        for candidate in candidates {
            let bodyTerms = terms(in: candidate.summary.title + " " + candidate.text)
            var score = 0
            for term in bodyTerms where queryTerms.contains(term) {
                score += 1
            }
            if score > 0 {
                scored.append(ScoredThread(summary: candidate.summary, score: score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.summary.updatedAt != rhs.summary.updatedAt {
                return lhs.summary.updatedAt > rhs.summary.updatedAt
            }
            return lhs.summary.id.uuidString > rhs.summary.id.uuidString
        }

        if let limit, limit >= 0, scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }
}
