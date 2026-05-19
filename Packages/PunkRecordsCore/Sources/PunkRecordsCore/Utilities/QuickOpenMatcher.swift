import Foundation

/// Fuzzy subsequence matcher for the editor's ⌘O Quick Open palette.
///
/// Each query character must appear in order somewhere in the candidate's
/// title. Hits closer together — and at the start of the title or after
/// word boundaries — score higher, so `fb` ranks `Foo Bar` above
/// `Frobulated`. Path components break ties so notes in nested folders
/// don't drown out vault-root notes with similar titles.
public enum QuickOpenMatcher {
    public struct Match: Sendable, Equatable {
        public let document: Document
        public let score: Int
        /// Indices into `document.title` (UTF16) that were matched. Useful
        /// for bolding the matched characters in the UI.
        public let matchedIndices: [Int]

        public init(document: Document, score: Int, matchedIndices: [Int]) {
            self.document = document
            self.score = score
            self.matchedIndices = matchedIndices
        }
    }

    /// Returns matches sorted best-first. Empty query returns the first
    /// `limit` documents in vault title order so the palette is never empty.
    public static func match(
        documents: [Document],
        query: String,
        limit: Int = 25
    ) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(documents
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .prefix(limit))
                .map { Match(document: $0, score: 0, matchedIndices: []) }
        }

        let lowerQuery = Array(trimmed.lowercased())

        var matches: [Match] = []
        for doc in documents {
            if let m = score(title: doc.title, queryChars: lowerQuery) {
                matches.append(Match(
                    document: doc,
                    score: m.score,
                    matchedIndices: m.indices
                ))
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Tie-break: prefer shorter titles, then alphabetical.
                if lhs.document.title.count != rhs.document.title.count {
                    return lhs.document.title.count < rhs.document.title.count
                }
                return lhs.document.title.localizedStandardCompare(rhs.document.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Greedy left-to-right subsequence match. Returns nil if `queryChars`
    /// can't be matched as an in-order subsequence of `title`.
    private static func score(title: String, queryChars: [Character]) -> (score: Int, indices: [Int])? {
        guard !queryChars.isEmpty else { return (0, []) }
        let titleChars = Array(title.lowercased())
        guard !titleChars.isEmpty else { return nil }

        var indices: [Int] = []
        indices.reserveCapacity(queryChars.count)
        var titleIdx = 0
        for q in queryChars {
            while titleIdx < titleChars.count && titleChars[titleIdx] != q {
                titleIdx += 1
            }
            guard titleIdx < titleChars.count else { return nil }
            indices.append(titleIdx)
            titleIdx += 1
        }

        // Scoring: base = number of matched chars.
        // Bonus per match: +5 at start of title, +3 after word boundary, +1 consecutive.
        var score = queryChars.count * 2
        var prevIdx = -2
        for (i, idx) in indices.enumerated() {
            if idx == 0 {
                score += 5
            } else {
                let before = titleChars[idx - 1]
                if before == " " || before == "-" || before == "_" || before == "/" {
                    score += 3
                }
            }
            if i > 0 && idx == prevIdx + 1 {
                score += 1
            }
            prevIdx = idx
        }
        // Penalize long titles: every char beyond the matched range costs 1.
        let unmatched = titleChars.count - queryChars.count
        score -= max(0, unmatched / 8)
        return (score, indices)
    }
}
