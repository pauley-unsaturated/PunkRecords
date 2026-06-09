import Foundation

public enum LLMProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case foundationModels = "apple.foundation-models"
    case anthropic = "anthropic"
    case openAI = "openai"
    case ollama = "ollama"
    case lmStudio = "lmstudio"

    /// Short user-visible label for picker chips and per-message attribution.
    /// Kept short so it fits in a small chip without truncation.
    public var displayName: String {
        switch self {
        case .foundationModels: return "Apple"
        case .anthropic: return "Claude"
        case .openAI: return "GPT"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    /// Whether this provider talks to a locally-hosted inference server (no API
    /// key, model discovery + inference stats available).
    public var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio: return true
        case .foundationModels, .anthropic, .openAI: return false
        }
    }
}
