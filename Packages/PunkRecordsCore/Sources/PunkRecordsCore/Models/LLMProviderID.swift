import Foundation

public enum LLMProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case foundationModels = "apple.foundation-models"
    case anthropic = "anthropic"
    case openAI = "openai"

    /// Short user-visible label for picker chips and per-message attribution.
    /// Intentionally one word so it fits in a small chip without truncation.
    public var displayName: String {
        switch self {
        case .foundationModels: return "Apple"
        case .anthropic: return "Claude"
        case .openAI: return "GPT"
        }
    }
}
