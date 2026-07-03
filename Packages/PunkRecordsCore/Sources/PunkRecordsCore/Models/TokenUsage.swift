import Foundation

/// Token accounting for one model call. The session path does not report usage
/// yet (PUNK-4bu tracks estimating it in `SessionAgentRunner`); the type remains
/// the currency eval metrics are denominated in, including the cache fields that
/// keep historical report schemas comparable.
public struct TokenUsage: Sendable, Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    /// Fraction of cached prompt tokens vs total cacheable tokens (0.0–1.0).
    public var cacheHitRate: Double {
        let total = cacheCreationInputTokens + cacheReadInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total)
    }

    public init(
        promptTokens: Int,
        completionTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}
