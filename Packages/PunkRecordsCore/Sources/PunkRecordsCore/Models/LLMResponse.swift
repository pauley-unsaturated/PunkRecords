import Foundation

public struct TokenUsage: Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
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
