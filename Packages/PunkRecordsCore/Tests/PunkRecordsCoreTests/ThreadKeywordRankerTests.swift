import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("ThreadKeywordRanker — deterministic keyword ranking over threads")
struct ThreadKeywordRankerTests {

    private func summary(_ title: String, updatedAt: Date = Date(timeIntervalSince1970: 0), id: UUID = UUID()) -> ThreadSummary {
        ThreadSummary(id: id, title: title, updatedAt: updatedAt, messageCount: 2)
    }

    @Test("Scores by term frequency across title + body, case-insensitively")
    func termFrequencyScoring() {
        let candidates = [
            (summary: summary("Guitar tone"), text: "guitar amp GUITAR distortion"),
            (summary: summary("Bread"), text: "sourdough baking"),
        ]
        let ranked = ThreadKeywordRanker.rank(query: "Guitar", candidates: candidates)
        #expect(ranked.count == 1)
        #expect(ranked.first?.summary.title == "Guitar tone")
        // "Guitar" appears in the title once and the body twice → tf of 3.
        #expect(ranked.first?.score == 3)
    }

    @Test("No query terms or no matches yields no results")
    func emptyResults() {
        let candidates = [(summary: summary("A"), text: "nothing relevant here")]
        #expect(ThreadKeywordRanker.rank(query: "   ", candidates: candidates).isEmpty)
        #expect(ThreadKeywordRanker.rank(query: "xyzzy", candidates: candidates).isEmpty)
    }

    @Test("Ties break by updatedAt desc, then id desc — deterministic across input order")
    func deterministicTiebreak() {
        let ts = Date(timeIntervalSince1970: 5_000)
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let a = (summary: summary("reverb", updatedAt: ts, id: low), text: "reverb")
        let b = (summary: summary("reverb", updatedAt: ts, id: high), text: "reverb")

        let forward = ThreadKeywordRanker.rank(query: "reverb", candidates: [a, b])
        let reverse = ThreadKeywordRanker.rank(query: "reverb", candidates: [b, a])
        #expect(forward == reverse)
        // Equal score + equal timestamp → higher id string sorts first.
        #expect(forward.first?.summary.id == high)
    }

    @Test("Higher score outranks a newer-but-weaker match")
    func scoreBeatsRecency() {
        let older = summary("delay delay delay", updatedAt: Date(timeIntervalSince1970: 1))
        let newer = summary("delay", updatedAt: Date(timeIntervalSince1970: 9_999))
        let candidates = [
            (summary: newer, text: ""),
            (summary: older, text: "delay delay"),
        ]
        let ranked = ThreadKeywordRanker.rank(query: "delay", candidates: candidates)
        #expect(ranked.map(\.summary.id) == [older.id, newer.id])
    }

    @Test("Limit caps the result count after sorting")
    func limitCaps() {
        let candidates = (0..<5).map { i in
            (summary: summary("match \(i)", updatedAt: Date(timeIntervalSince1970: Double(i))), text: "match")
        }
        let ranked = ThreadKeywordRanker.rank(query: "match", candidates: candidates, limit: 2)
        #expect(ranked.count == 2)
    }
}
