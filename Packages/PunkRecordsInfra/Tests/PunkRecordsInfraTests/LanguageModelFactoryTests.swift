import AnyLanguageModel
import Foundation
import PunkRecordsCore
import Testing
@testable import PunkRecordsInfra

/// Unit tests for ``LanguageModelFactory`` — the provider → `LanguageModel`
/// mapping. These assert construction succeeds (no throw, a real model back) for
/// the provider cases that need no credentials. No network or model inference is
/// exercised; building a `LanguageModel` value is purely local.
@Suite("LanguageModelFactory model construction")
struct LanguageModelFactoryTests {

    /// A throwaway Keychain service on an isolated service name so tests never
    /// touch the app's real credentials.
    private func makeKeychain() -> KeychainService {
        KeychainService(service: "com.markpauley.PunkRecords.tests.\(UUID().uuidString)")
    }

    @Test("Returns a model for .anyLanguageModel without throwing")
    func anyLanguageModelBuilds() throws {
        let model = try LanguageModelFactory.makeModel(
            for: .anyLanguageModel,
            keychain: makeKeychain()
        )
        // A non-throwing construction yields a usable model value; touching a
        // protocol member confirms it is a real, queryable model (not a stub).
        _ = model.isAvailable
    }

    @Test("Returns a model for .foundationModels without throwing")
    func foundationModelsBuilds() throws {
        let model = try LanguageModelFactory.makeModel(
            for: .foundationModels,
            keychain: makeKeychain()
        )
        _ = model.isAvailable
    }

    @Test("Local backend honours a custom Ollama model id and endpoint")
    func anyLanguageModelHonoursConfig() throws {
        let config = LanguageModelFactory.Config(
            ollamaModel: "llama3.3",
            ollamaEndpoint: URL(string: "http://localhost:9999")!
        )
        let model = try LanguageModelFactory.makeModel(
            for: .anyLanguageModel,
            keychain: makeKeychain(),
            config: config
        )
        let ollama = try #require(model as? OllamaLanguageModel)
        #expect(ollama.model == "llama3.3")
        #expect(ollama.baseURL.host == "localhost")
        #expect(ollama.baseURL.port == 9999)
    }

    @Test(".anthropic builds a remote Claude model when a key is present")
    func anthropicBuildsWithKey() throws {
        // .anthropic now maps to AnyLanguageModel's remote AnthropicLanguageModel
        // (not the on-device fallback). With a stored key it must construct without
        // throwing; building the value is local and makes no network call.
        let keychain = makeKeychain()
        try keychain.setAPIKey("sk-ant-test-key", for: "anthropic")
        defer { try? keychain.removeAPIKey(for: "anthropic") }

        let model = try LanguageModelFactory.makeModel(
            for: .anthropic,
            keychain: keychain
        )
        let anthropic = try #require(model as? AnthropicLanguageModel)
        #expect(anthropic.model == "claude-sonnet-4-6")
    }

    @Test(".anthropic honours a custom Claude model id from config")
    func anthropicHonoursConfig() throws {
        let keychain = makeKeychain()
        try keychain.setAPIKey("sk-ant-test-key", for: "anthropic")
        defer { try? keychain.removeAPIKey(for: "anthropic") }

        let config = LanguageModelFactory.Config(claudeModel: "claude-3-5-sonnet-20241022")
        let model = try LanguageModelFactory.makeModel(
            for: .anthropic,
            keychain: keychain,
            config: config
        )
        let anthropic = try #require(model as? AnthropicLanguageModel)
        #expect(anthropic.model == "claude-3-5-sonnet-20241022")
    }

    @Test(".anthropic throws missingAPIKey when no key is stored")
    func anthropicMissingKeyThrows() {
        let keychain = makeKeychain()
        #expect(throws: LanguageModelFactory.FactoryError.missingAPIKey(provider: "anthropic")) {
            _ = try LanguageModelFactory.makeModel(for: .anthropic, keychain: keychain)
        }
    }

    @Test(".openAI throws missingAPIKey when no key is stored")
    func openAIMissingKeyThrows() {
        let keychain = makeKeychain()
        #expect(throws: LanguageModelFactory.FactoryError.missingAPIKey(provider: "openai")) {
            _ = try LanguageModelFactory.makeModel(for: .openAI, keychain: keychain)
        }
    }

    @Test("Remote providers are available without stored keys")
    func remoteProvidersDoNotRequireKeysForAvailability() async {
        let keychain = makeKeychain()

        #expect(await LanguageModelFactory.isAvailable(.anthropic, keychain: keychain))
        #expect(await LanguageModelFactory.isAvailable(.openAI, keychain: keychain))
    }

    // MARK: - modelIdentifier

    @Test("modelIdentifier reads the per-provider model id from config, no Keychain/network touched")
    func modelIdentifierReadsFromConfig() {
        let config = LanguageModelFactory.Config(
            ollamaModel: "llama3.3",
            openAIModel: "gpt-4o-mini",
            claudeModel: "claude-3-5-sonnet-20241022"
        )
        #expect(LanguageModelFactory.modelIdentifier(for: .anthropic, config: config) == "claude-3-5-sonnet-20241022")
        #expect(LanguageModelFactory.modelIdentifier(for: .openAI, config: config) == "gpt-4o-mini")
        #expect(LanguageModelFactory.modelIdentifier(for: .anyLanguageModel, config: config) == "llama3.3")
    }

    @Test("modelIdentifier returns a stable label for .foundationModels (no user-tunable model id)")
    func modelIdentifierFoundationModels() {
        #expect(LanguageModelFactory.modelIdentifier(for: .foundationModels) == "apple.foundation-models")
    }

    @Test("modelIdentifier matches what makeModel actually constructs")
    func modelIdentifierMatchesConstructedModel() throws {
        let config = LanguageModelFactory.Config(claudeModel: "claude-3-5-sonnet-20241022")
        let keychain = makeKeychain()
        try keychain.setAPIKey("sk-ant-test-key", for: "anthropic")
        defer { try? keychain.removeAPIKey(for: "anthropic") }

        let model = try LanguageModelFactory.makeModel(for: .anthropic, keychain: keychain, config: config)
        let anthropic = try #require(model as? AnthropicLanguageModel)
        #expect(LanguageModelFactory.modelIdentifier(for: .anthropic, config: config) == anthropic.model)
    }
}
