import Foundation

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

public struct LLMResponse: Sendable {
    public let text: String
    public let providerID: LLMProviderID
    public let usedDocuments: [DocumentID]
    public let usage: TokenUsage?

    public init(
        text: String,
        providerID: LLMProviderID,
        usedDocuments: [DocumentID] = [],
        usage: TokenUsage? = nil
    ) {
        self.text = text
        self.providerID = providerID
        self.usedDocuments = usedDocuments
        self.usage = usage
    }
}
