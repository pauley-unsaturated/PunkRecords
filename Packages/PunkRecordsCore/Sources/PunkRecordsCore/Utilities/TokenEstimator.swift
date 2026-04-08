import Foundation

/// Estimates token counts using the approximation of 1 token ~ 4 characters.
/// This is a Phase 1 simplification; exact per-provider tokenizers are Phase 3.
public enum TokenEstimator {
    public static func estimateTokens(in text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    public static func estimateTokens(in documents: [DocumentExcerpt]) -> Int {
        documents.reduce(0) { $0 + estimateTokens(in: $1.excerpt) + estimateTokens(in: $1.title) }
    }

    public static func truncateToTokenBudget(_ text: String, budget: Int) -> String {
        let charBudget = budget * 4
        guard text.count > charBudget else { return text }

        let truncated = String(text.prefix(charBudget))
        // Try to truncate at a sentence boundary
        if let lastPeriod = truncated.lastIndex(of: ".") {
            let distance = truncated.distance(from: truncated.startIndex, to: lastPeriod)
            if distance > charBudget / 2 {
                return String(truncated[...lastPeriod])
            }
        }
        // Fall back to word boundary
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace])
        }
        return truncated
    }
}
