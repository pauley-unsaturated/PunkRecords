import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// Maps a PunkRecords ``LLMProviderID`` (plus credentials and optional config) to
/// a concrete AnyLanguageModel ``LanguageModel`` that the session path
/// (``SessionAgentRunner``) can drive.
///
/// This is the M3 strangler-fig seam: instead of resolving an `LLMProvider`
/// actor (which owns the old hand-rolled request shape), callers resolve a
/// `LanguageModel` and hand it to a `LanguageModelSession`, letting the session
/// own the agentic tool loop. Core stays pure — it never names AnyLanguageModel /
/// FoundationModels; this Infra factory does the one-way mapping.
///
/// Return type is `any AnyLanguageModel.LanguageModel` deliberately: that is what
/// ``SessionAgentRunner/init(model:instructions:tools:options:)`` consumes, and
/// every backend here (`OllamaLanguageModel`, `OpenAILanguageModel`, and ALM's
/// `SystemLanguageModel` bridge) conforms to it. ADDITIVE — not yet wired into the
/// UI; the existing `LLMProvider`/`LLMOrchestrator` path is untouched.
///
/// ## Provider mapping
/// | Provider             | Backend                                            |
/// | -------------------- | -------------------------------------------------- |
/// | `.anyLanguageModel`  | `OllamaLanguageModel` (default `qwen3` @ localhost) |
/// | `.openAI`            | `OpenAILanguageModel`, key from Keychain `"openai"` |
/// | `.foundationModels`  | ALM `SystemLanguageModel` (macOS 26+ on-device)     |
/// | `.anthropic`         | *fallback* — see the `.anthropic` note below        |
///
/// ## `.anthropic` — known limitation
/// Anthropic's `ClaudeForFoundationModels` (`ClaudeLanguageModel`) conforms to the
/// **system** `FoundationModels.LanguageModel` protocol (the macOS 26+ executor
/// model), which is structurally *different* from AnyLanguageModel's
/// `LanguageModel` and therefore cannot be returned through this factory's
/// `any AnyLanguageModel.LanguageModel` type — nor driven by AnyLanguageModel's
/// `LanguageModelSession`. Wiring it requires a parallel session path on
/// `FoundationModels.LanguageModelSession`, which is a separate workflow. Until
/// then `.anthropic` falls back to the on-device `SystemLanguageModel` so the
/// factory stays total and green.
public enum LanguageModelFactory {

    /// Optional per-call configuration. Defaults match the existing providers.
    public struct Config: Sendable {
        /// Model identifier for the local Ollama backend (`.anyLanguageModel`).
        public var ollamaModel: String
        /// Endpoint for the local Ollama server.
        public var ollamaEndpoint: URL
        /// Model identifier for the OpenAI backend (`.openAI`).
        public var openAIModel: String

        public init(
            ollamaModel: String = "qwen3",
            ollamaEndpoint: URL = URL(string: "http://localhost:11434")!,
            openAIModel: String = "gpt-4o"
        ) {
            self.ollamaModel = ollamaModel
            self.ollamaEndpoint = ollamaEndpoint
            self.openAIModel = openAIModel
        }
    }

    /// Errors surfaced while constructing a model (distinct from runtime
    /// generation errors, which the session raises later).
    public enum FactoryError: Error, Sendable, Equatable {
        /// The provider needs an API key that was not present in the Keychain.
        case missingAPIKey(provider: String)
    }

    /// Build the backing ``LanguageModel`` for `provider`.
    ///
    /// - Parameters:
    ///   - provider: Which backend to construct.
    ///   - keychain: Source for API keys. Keys use the literal provider strings
    ///     `"openai"` / `"anthropic"` (matching the existing providers and
    ///     `SettingsView`), not the `LLMProviderID` raw values.
    ///   - config: Backend tuning (model ids / endpoint). Defaults provided.
    /// - Returns: A model ready to hand to a `LanguageModelSession`.
    /// - Throws: ``FactoryError/missingAPIKey(provider:)`` when a remote provider
    ///   has no stored key, or any Keychain read error.
    public static func makeModel(
        for provider: LLMProviderID,
        keychain: KeychainService,
        config: Config = Config()
    ) throws -> any AnyLanguageModel.LanguageModel {
        switch provider {
        case .anyLanguageModel:
            return OllamaLanguageModel(baseURL: config.ollamaEndpoint, model: config.ollamaModel)

        case .openAI:
            let key = try requireKey(from: keychain, provider: "openai")
            return OpenAILanguageModel(apiKey: key, model: config.openAIModel)

        case .foundationModels:
            return makeSystemLanguageModel()

        case .anthropic:
            // TODO(PUNK): wire ClaudeForFoundationModels (ClaudeLanguageModel) once
            // there is a FoundationModels.LanguageModelSession-based driver. It
            // conforms to the system FoundationModels.LanguageModel protocol, which
            // is incompatible with this factory's AnyLanguageModel.LanguageModel
            // return type and AnyLanguageModel's session path. Falling back to the
            // on-device model keeps the factory total until that path exists.
            return makeSystemLanguageModel()
        }
    }

    // MARK: - Helpers

    /// ALM's `SystemLanguageModel` bridges to Apple's on-device FoundationModels
    /// model. It is gated `@available(macOS 26, *)`; the deployment target is
    /// macOS 27, so the symbol is unconditionally available here. Returned even
    /// when the device reports it unavailable — availability is the caller's
    /// concern (`model.isAvailable`), and the factory's job is construction.
    private static func makeSystemLanguageModel() -> any AnyLanguageModel.LanguageModel {
        SystemLanguageModel()
    }

    /// Read a required API key or throw ``FactoryError/missingAPIKey(provider:)``.
    private static func requireKey(
        from keychain: KeychainService,
        provider: String
    ) throws -> String {
        guard let key = try keychain.apiKey(for: provider), !key.isEmpty else {
            throw FactoryError.missingAPIKey(provider: provider)
        }
        return key
    }
}
