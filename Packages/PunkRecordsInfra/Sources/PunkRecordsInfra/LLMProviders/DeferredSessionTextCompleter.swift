import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// A ``TextCompleter`` that resolves its backing model **at completion time**
/// instead of when the vault opens.
///
/// This replaces the legacy fallback chain (eager `SessionTextCompleter` if the
/// model could be built at vault-open, else the `LLMOrchestrator`). Deferring
/// resolution has two effects:
/// - an API key added in Settings while a vault is open starts working on the
///   next save/compile, with no vault reopen;
/// - a missing key surfaces as a thrown, user-visible error from the action
///   that needed it, instead of silently routing to a legacy path that would
///   fail on the same missing key anyway.
public struct DeferredSessionTextCompleter: TextCompleter {
    private let provider: LLMProviderID
    private let keychain: KeychainService
    private let config: LanguageModelFactory.Config

    public init(
        provider: LLMProviderID,
        keychain: KeychainService,
        config: LanguageModelFactory.Config = LanguageModelFactory.Config()
    ) {
        self.provider = provider
        self.keychain = keychain
        self.config = config
    }

    public func complete(prompt: String) async throws -> String {
        let model = try LanguageModelFactory.makeModel(for: provider, keychain: keychain, config: config)
        return try await SessionTextCompleter(model: model).complete(prompt: prompt)
    }
}
