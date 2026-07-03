import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// A ``TextCompleter`` that resolves its backing model **at completion time**
/// instead of when the vault opens.
///
/// Both the provider and the endpoint config are resolved through closures on
/// every call, so note compilation always follows the CURRENT selection — the
/// same provider the chat panel targets — and settings changed while a vault
/// is open (a new API key, a different provider, another Ollama endpoint)
/// apply to the next save/compile with no vault reopen. A missing key
/// surfaces as a thrown, user-visible error from the action that needed it.
public struct DeferredSessionTextCompleter: TextCompleter {
    private let provider: @Sendable () -> LLMProviderID
    private let keychain: KeychainService
    private let config: @Sendable () -> LanguageModelFactory.Config

    public init(
        provider: @escaping @Sendable () -> LLMProviderID,
        keychain: KeychainService,
        config: @escaping @Sendable () -> LanguageModelFactory.Config = { .fromUserDefaults() }
    ) {
        self.provider = provider
        self.keychain = keychain
        self.config = config
    }

    /// Fixed-provider convenience (tests, one-off callers).
    public init(
        provider: LLMProviderID,
        keychain: KeychainService,
        config: LanguageModelFactory.Config = LanguageModelFactory.Config()
    ) {
        self.init(provider: { provider }, keychain: keychain, config: { config })
    }

    public func complete(prompt: String) async throws -> String {
        let model = try LanguageModelFactory.makeModel(for: provider(), keychain: keychain, config: config())
        return try await SessionTextCompleter(model: model).complete(prompt: prompt)
    }
}
