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
/// | `.anthropic`         | `AnthropicLanguageModel`, key from Keychain `"anthropic"` |
///
/// ## `.anthropic` — backend choice
/// `.anthropic` uses AnyLanguageModel's **remote** `AnthropicLanguageModel`, which
/// talks to Claude's Messages API and conforms to *this* factory's
/// `any AnyLanguageModel.LanguageModel` protocol — so it is driven by the same
/// `LanguageModelSession`/`SessionAgentRunner` tool loop as every other backend,
/// with no parallel session path.
///
/// We deliberately do **not** use Anthropic's official `ClaudeForFoundationModels`
/// (`ClaudeLanguageModel`) here. That type conforms to the *system*
/// `FoundationModels.LanguageModel` protocol (the macOS 26+ executor model) and
/// can offer server-side tools / Private Cloud Compute, but it is structurally
/// *different* from AnyLanguageModel's `LanguageModel` and would require a parallel
/// `FoundationModels.LanguageModelSession` driver. Keeping `.anthropic` on the
/// AnyLanguageModel-native remote backend means every provider shares one unified
/// session path. The system-protocol `ClaudeForFoundationModels` remains a
/// deliberate future option, not used here.
public enum LanguageModelFactory {

    /// Optional per-call configuration. Defaults match the existing providers.
    public struct Config: Sendable {
        /// Model identifier for the local Ollama backend (`.anyLanguageModel`).
        public var ollamaModel: String
        /// Endpoint for the local Ollama server.
        public var ollamaEndpoint: URL
        /// Model identifier for the OpenAI backend (`.openAI`).
        public var openAIModel: String
        /// Model identifier for the Anthropic backend (`.anthropic`). Defaults to
        /// the same Claude model the legacy `AnthropicProvider` uses.
        public var claudeModel: String

        public init(
            ollamaModel: String = "qwen3",
            ollamaEndpoint: URL = URL(string: "http://localhost:11434")!,
            openAIModel: String = "gpt-4o",
            claudeModel: String = "claude-sonnet-4-6"
        ) {
            self.ollamaModel = ollamaModel
            self.ollamaEndpoint = ollamaEndpoint
            self.openAIModel = openAIModel
            self.claudeModel = claudeModel
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
            // AnyLanguageModel's remote Anthropic backend: conforms to this
            // factory's `any AnyLanguageModel.LanguageModel` and is driven by the
            // same `LanguageModelSession`/`SessionAgentRunner` tool loop as every
            // other provider. We intentionally do NOT use Anthropic's official
            // `ClaudeForFoundationModels` (`ClaudeLanguageModel`), which conforms to
            // the *system* FoundationModels.LanguageModel protocol and could add
            // server-side tools / Private Cloud Compute — that would force a
            // parallel FoundationModels.LanguageModelSession driver and split the
            // session path. Keeping one unified session path is the deliberate
            // choice; the system-protocol backend stays a future option.
            let key = try requireKey(from: keychain, provider: "anthropic")
            return AnthropicLanguageModel(apiKey: key, model: config.claudeModel)
        }
    }

    // MARK: - Availability

    /// The providers this factory can currently build a usable model for — i.e.
    /// the ones the chat UI should leave selectable. This reflects the SESSION
    /// path (not the legacy `LLMOrchestrator`): a remote provider is available
    /// when its API key is stored, the local Ollama provider when its server
    /// answers, and the on-device provider when Apple reports the model ready.
    public static func availableProviders(
        keychain: KeychainService,
        config: Config = Config()
    ) async -> [LLMProviderID] {
        var result: [LLMProviderID] = []
        for provider in LLMProviderID.allCases where await isAvailable(provider, keychain: keychain, config: config) {
            result.append(provider)
        }
        return result
    }

    /// Whether `provider` can be constructed and used right now.
    public static func isAvailable(
        _ provider: LLMProviderID,
        keychain: KeychainService,
        config: Config = Config()
    ) async -> Bool {
        switch provider {
        case .anyLanguageModel:
            return await ollamaReachable(config.ollamaEndpoint)
        case .openAI:
            return hasKey(keychain, "openai")
        case .anthropic:
            return hasKey(keychain, "anthropic")
        case .foundationModels:
            return systemModelAvailable()
        }
    }

    private static func hasKey(_ keychain: KeychainService, _ provider: String) -> Bool {
        ((try? keychain.apiKey(for: provider)) ?? nil)?.isEmpty == false
    }

    /// Probe the Ollama server's `/api/tags` with a short timeout. Any reachable
    /// HTTP response (even an error status) means the daemon is up.
    private static func ollamaReachable(_ endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("/api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Whether Apple's on-device system model reports itself ready (Apple
    /// Intelligence enabled and the model downloaded).
    private static func systemModelAvailable() -> Bool {
        if case .available = SystemLanguageModel().availability { return true }
        return false
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
