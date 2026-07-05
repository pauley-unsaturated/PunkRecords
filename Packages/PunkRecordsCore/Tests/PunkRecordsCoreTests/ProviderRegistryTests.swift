import Foundation
import Testing
@testable import PunkRecordsCore

/// Unit tests for ``ProviderRegistry`` — the single source of truth for
/// per-provider LLM settings, defaults, endpoint parsing, capabilities, and
/// context budgets. These pin the values every consumer (SettingsView,
/// LLMChatPanel, AppState, LanguageModelFactory) now delegates to, so a change
/// that would silently alter a persisted key, a default, or a capability answer
/// fails here first.
@Suite("ProviderRegistry")
struct ProviderRegistryTests {

    // MARK: - Persistence keys (load-bearing: renaming drops user settings)

    @Test("UserDefaults key names match the persisted values users already have")
    func defaultsKeys() {
        #expect(ProviderRegistry.DefaultsKey.chatProvider == "chatProviderID")
        #expect(ProviderRegistry.DefaultsKey.ollamaModel == "ollama.model")
        #expect(ProviderRegistry.DefaultsKey.ollamaBaseURL == "ollama.baseURL")
        #expect(ProviderRegistry.DefaultsKey.openAIBaseURL == "openai.baseURL")
    }

    @Test("Keychain account names match the strings keys are stored under")
    func keychainAccounts() {
        #expect(ProviderRegistry.KeychainAccount.anthropic == "anthropic")
        #expect(ProviderRegistry.KeychainAccount.openAI == "openai")
    }

    @Test("Keychain account maps only for providers that need a stored key")
    func keychainAccountForProvider() {
        #expect(ProviderRegistry.keychainAccount(for: .anthropic) == "anthropic")
        #expect(ProviderRegistry.keychainAccount(for: .openAI) == "openai")
        #expect(ProviderRegistry.keychainAccount(for: .anyLanguageModel) == nil)
        #expect(ProviderRegistry.keychainAccount(for: .foundationModels) == nil)
    }

    // MARK: - Defaults

    @Test("Default model ids and endpoints match the shipped provider defaults")
    func defaults() {
        #expect(ProviderRegistry.chatProviderDefault == .anthropic)
        #expect(ProviderRegistry.defaultOllamaModel == "qwen3")
        #expect(ProviderRegistry.defaultOllamaBaseURL == "http://localhost:11434")
        #expect(ProviderRegistry.defaultOpenAIModel == "gpt-4o")
        #expect(ProviderRegistry.defaultClaudeModel == "claude-sonnet-4-6")
        #expect(ProviderRegistry.defaultOpenAIBaseURL == "")
        #expect(ProviderRegistry.defaultOllamaEndpoint == URL(string: "http://localhost:11434"))
    }

    // MARK: - Ollama model parsing

    @Test("Ollama model falls back to the default when nil or blank")
    func ollamaModelFallback() {
        #expect(ProviderRegistry.ollamaModel(from: nil) == "qwen3")
        #expect(ProviderRegistry.ollamaModel(from: "") == "qwen3")
    }

    @Test("Ollama model honours a custom id")
    func ollamaModelCustom() {
        #expect(ProviderRegistry.ollamaModel(from: "llama3.3") == "llama3.3")
    }

    // MARK: - Ollama endpoint parsing (valid / invalid / custom)

    @Test("Ollama endpoint falls back to default when nil or blank")
    func ollamaEndpointFallback() {
        #expect(ProviderRegistry.ollamaEndpoint(from: nil) == URL(string: "http://localhost:11434"))
        #expect(ProviderRegistry.ollamaEndpoint(from: "") == URL(string: "http://localhost:11434"))
    }

    @Test("Ollama endpoint honours a custom, well-formed base URL")
    func ollamaEndpointCustom() {
        let url = ProviderRegistry.ollamaEndpoint(from: "http://localhost:9999")
        #expect(url.host == "localhost")
        #expect(url.port == 9999)
    }

    @Test("Ollama endpoint falls back to default when the string is unparseable")
    func ollamaEndpointInvalid() {
        // A control character makes URL(string:) return nil, forcing the default.
        #expect(ProviderRegistry.ollamaEndpoint(from: "ht tp://\u{7f}bad") == URL(string: "http://localhost:11434"))
    }

    // MARK: - OpenAI endpoint parsing (blank = official / nil)

    @Test("OpenAI endpoint is nil (official API) when nil or blank")
    func openAIEndpointOfficial() {
        #expect(ProviderRegistry.openAIEndpoint(from: nil) == nil)
        #expect(ProviderRegistry.openAIEndpoint(from: "") == nil)
    }

    @Test("OpenAI endpoint honours a custom OpenAI-compatible base URL")
    func openAIEndpointCustom() {
        let url = ProviderRegistry.openAIEndpoint(from: "http://localhost:1234/v1")
        #expect(url?.host == "localhost")
        #expect(url?.port == 1234)
        #expect(url?.path == "/v1")
    }

    @Test("OpenAI endpoint is nil when the string is unparseable")
    func openAIEndpointInvalid() {
        #expect(ProviderRegistry.openAIEndpoint(from: "ht tp://\u{7f}bad") == nil)
    }

    // MARK: - Chat provider resolution

    @Test("Chat provider round-trips a known raw value")
    func chatProviderKnown() {
        for id in LLMProviderID.allCases {
            #expect(ProviderRegistry.chatProvider(from: id.rawValue) == id)
        }
    }

    @Test("Chat provider falls back for nil or unknown raw values")
    func chatProviderFallback() {
        #expect(ProviderRegistry.chatProvider(from: nil) == .anthropic)
        #expect(ProviderRegistry.chatProvider(from: "bogus") == .anthropic)
        // Explicit fallback overrides the default.
        #expect(ProviderRegistry.chatProvider(from: nil, default: .openAI) == .openAI)
        #expect(ProviderRegistry.chatProvider(from: "bogus", default: .foundationModels) == .foundationModels)
    }

    // MARK: - Image capability lookup

    @Test("Native image input matches each provider's capability")
    func nativeImageInput() {
        #expect(ProviderRegistry.nativeImageInput(.anthropic))
        #expect(ProviderRegistry.nativeImageInput(.openAI))
        #expect(ProviderRegistry.nativeImageInput(.anyLanguageModel))
        #expect(!ProviderRegistry.nativeImageInput(.foundationModels))
    }

    @Test("Maximum image edge matches each provider's limit")
    func maximumImageEdge() {
        #expect(ProviderRegistry.maximumImageEdge(.anthropic) == 1_568)
        #expect(ProviderRegistry.maximumImageEdge(.openAI) == 2_048)
        #expect(ProviderRegistry.maximumImageEdge(.anyLanguageModel) == 2_048)
        #expect(ProviderRegistry.maximumImageEdge(.foundationModels) == 0)
    }

    @Test("LLMProviderID capability accessors delegate to the registry")
    func enumAccessorsDelegate() {
        for id in LLMProviderID.allCases {
            #expect(id.nativeImageInput == ProviderRegistry.nativeImageInput(id))
            #expect(id.maximumImageEdge == ProviderRegistry.maximumImageEdge(id))
        }
    }

    // MARK: - Context budget lookup

    @Test("Context budget matches each provider's conservative window")
    func contextBudget() {
        #expect(ProviderRegistry.contextBudget(for: .foundationModels) == 4_000)
        #expect(ProviderRegistry.contextBudget(for: .anyLanguageModel) == 8_192)
        #expect(ProviderRegistry.contextBudget(for: .openAI) == 128_000)
        #expect(ProviderRegistry.contextBudget(for: .anthropic) == 200_000)
    }
}
