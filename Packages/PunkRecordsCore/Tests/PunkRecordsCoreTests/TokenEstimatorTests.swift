import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("Token Estimator Tests")
struct TokenEstimatorTests {

    // MARK: - estimateTokens

    @Test("Basic token estimation uses ~4 chars per token")
    func basicEstimation() {
        // 20 chars / 4 = 5 tokens (utf8 count matches char count for ASCII)
        let text = "Hello, world! 12345!" // 20 ASCII chars
        #expect(TokenEstimator.estimateTokens(in: text) == text.utf8.count / 4)
    }

    @Test("Empty string returns 1 (minimum token count)")
    func emptyString() {
        // 0 / 4 = 0, but max(1, 0) = 1
        #expect(TokenEstimator.estimateTokens(in: "") == 1)
    }

    @Test("Short string returns minimum of 1 token")
    func shortString() {
        #expect(TokenEstimator.estimateTokens(in: "Hi") == 1)
    }

    @Test("Multi-byte characters counted by UTF-8 byte length")
    func multibyte() {
        let emoji = "🎸" // 4 UTF-8 bytes
        #expect(TokenEstimator.estimateTokens(in: emoji) == 1)
    }

    @Test("Estimates tokens across multiple document excerpts")
    func documentExcerpts() {
        let excerpts = [
            DocumentExcerpt(
                documentID: DocumentID(),
                title: "ABCD",       // 4 bytes -> 1 token
                excerpt: "ABCDABCD", // 8 bytes -> 2 tokens
                relevanceScore: 1.0
            ),
            DocumentExcerpt(
                documentID: DocumentID(),
                title: "ABCDABCD",       // 8 bytes -> 2 tokens
                excerpt: "ABCDABCDABCD", // 12 bytes -> 3 tokens
                relevanceScore: 0.5
            ),
        ]
        // Total: (1+2) + (2+3) = 8
        #expect(TokenEstimator.estimateTokens(in: excerpts) == 8)
    }

    // MARK: - truncateToTokenBudget

    @Test("Returns unchanged text when under budget")
    func underBudget() {
        let text = "Short text."
        let result = TokenEstimator.truncateToTokenBudget(text, budget: 100)
        #expect(result == text)
    }

    @Test("Returns unchanged text when exactly at budget")
    func atBudget() {
        // 8 chars, budget of 2 tokens = 8 char budget
        let text = "Exactly!" // 8 chars
        let result = TokenEstimator.truncateToTokenBudget(text, budget: 2)
        #expect(result == text)
    }

    @Test("Truncates at sentence boundary when possible")
    func sentenceBoundary() {
        // Budget: 5 tokens = 20 chars
        // Text has a period at a reasonable position (> half of 20 = 10)
        let text = "First sentence. Second sentence is longer and exceeds the budget easily."
        let result = TokenEstimator.truncateToTokenBudget(text, budget: 5)
        #expect(result == "First sentence.")
    }

    @Test("Falls back to word boundary when sentence boundary is too early")
    func wordBoundary() {
        // Budget: 3 tokens = 12 chars
        // "A. " has a period at index 1, which is < 12/2=6, so it won't use sentence boundary
        let text = "A. Some longer words here that go on"
        let result = TokenEstimator.truncateToTokenBudget(text, budget: 3)
        // prefix(12) = "A. Some long", last space at index 7 -> "A. Some"
        #expect(result == "A. Some")
    }

    @Test("Falls back to hard truncation when no spaces or periods")
    func hardTruncation() {
        let text = "abcdefghijklmnopqrstuvwxyz"
        // Budget: 2 tokens = 8 chars
        let result = TokenEstimator.truncateToTokenBudget(text, budget: 2)
        #expect(result == "abcdefgh")
    }
}
