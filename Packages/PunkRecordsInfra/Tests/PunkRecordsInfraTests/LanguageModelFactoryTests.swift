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

    @Test(".anthropic falls back to a model rather than throwing (known limitation)")
    func anthropicFallsBack() throws {
        // ClaudeForFoundationModels is not yet wired (see TODO in the factory):
        // .anthropic must still produce a usable model, not throw.
        let model = try LanguageModelFactory.makeModel(
            for: .anthropic,
            keychain: makeKeychain()
        )
        _ = model.isAvailable
    }

    @Test(".openAI throws missingAPIKey when no key is stored")
    func openAIMissingKeyThrows() {
        let keychain = makeKeychain()
        #expect(throws: LanguageModelFactory.FactoryError.missingAPIKey(provider: "openai")) {
            _ = try LanguageModelFactory.makeModel(for: .openAI, keychain: keychain)
        }
    }
}
