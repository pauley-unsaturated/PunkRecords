import Foundation

/// Token accounting for one model round. AnyLanguageModel exposes no real
/// usage, so the session runner reports `TokenEstimator` heuristics
/// (~4 chars/token) through `AgentEvent.turnEnd`. Cache fields remain so
/// historical eval-report schemas stay comparable; they read zero until a
/// backend surfaces real cache accounting.
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
