import Foundation

public enum LLMProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case foundationModels = "apple.foundation-models"
    case anthropic = "anthropic"
    case openAI = "openai"
    /// Local models via Hugging Face's AnyLanguageModel package (Ollama backend).
    case anyLanguageModel = "huggingface.any-language-model"

    /// Short user-visible label for picker chips and per-message attribution.
    /// Intentionally one word so it fits in a small chip without truncation.
    public var displayName: String {
        switch self {
        case .foundationModels: return "Apple"
        case .anthropic: return "Claude"
        case .openAI: return "GPT"
        case .anyLanguageModel: return "Ollama"
        }
    }

    /// Whether this provider accepts image attachments natively.
    /// Authoritative table lives in ``ProviderRegistry`` — this is a convenience
    /// accessor so call sites can read `provider.nativeImageInput`.
    public var nativeImageInput: Bool {
        ProviderRegistry.nativeImageInput(self)
    }

    /// Longest image edge (px) accepted before downscaling. Delegates to the
    /// single source of truth in ``ProviderRegistry``.
    public var maximumImageEdge: Int {
        ProviderRegistry.maximumImageEdge(self)
    }
}
