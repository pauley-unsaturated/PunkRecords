import Foundation

public enum LLMProviderID: String, Codable, Sendable, Hashable {
    case foundationModels = "apple.foundation-models"
    case anthropic = "anthropic"
    case openAI = "openai"
}
