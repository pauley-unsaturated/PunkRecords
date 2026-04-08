import Testing
import PunkRecordsCore
import PunkRecordsTestSupport

@Suite("LLMOrchestrator Tests")
struct LLMOrchestratorTests {

    private func makeOrchestrator(
        provider: MockLLMProvider? = nil,
        documents: [Document] = []
    ) async -> (LLMOrchestrator, MockLLMProvider) {
        let search = MockSearchService()
        let repo = MockDocumentRepository(documents: documents)
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let mock = provider ?? MockLLMProvider()
        let orch = LLMOrchestrator(
            contextBuilder: contextBuilder,
            defaultProviderID: mock.id,
            vaultName: "TestVault"
        )
        await orch.registerProvider(mock)
        return (orch, mock)
    }

    @Test("ask returns streamed tokens from provider")
    func askStreamsTokens() async throws {
        let (orch, _) = await makeOrchestrator(
            provider: MockLLMProvider(responses: ["Hello world"])
        )

        let stream = try await orch.ask(prompt: "test", scope: .global)
        var collected = ""
        for try await event in stream {
            switch event {
            case .token(let t): collected += t
            case .done: break
            case .citation, .error: break
            }
        }

        #expect(collected == "Hello world")
    }

    @Test("complete returns full response")
    func completeReturnsResponse() async throws {
        let (orch, _) = await makeOrchestrator(
            provider: MockLLMProvider(
                capabilities: [],
                responses: ["Complete response"]
            )
        )

        let response = try await orch.complete(prompt: "test", scope: .global)
        #expect(response.text == "Complete response")
    }

    @Test("throws when no providers are registered")
    func noProviders() async throws {
        let search = MockSearchService()
        let repo = MockDocumentRepository()
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let orch = LLMOrchestrator(
            contextBuilder: contextBuilder,
            defaultProviderID: .anthropic,
            vaultName: "TestVault"
        )

        await #expect(throws: LLMError.self) {
            _ = try await orch.complete(prompt: "test", scope: .global)
        }
    }

    @Test("falls back to another provider when default is unavailable")
    func fallbackProvider() async throws {
        let search = MockSearchService()
        let repo = MockDocumentRepository()
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let orch = LLMOrchestrator(
            contextBuilder: contextBuilder,
            defaultProviderID: .anthropic,
            vaultName: "TestVault"
        )

        let unavailable = MockLLMProvider(
            id: .anthropic,
            capabilities: [],
            responses: ["wrong"],
            isAvailable: false
        )
        let fallback = MockLLMProvider(
            id: .openAI,
            capabilities: [],
            responses: ["fallback response"],
            isAvailable: true
        )
        await orch.registerProvider(unavailable)
        await orch.registerProvider(fallback)

        let response = try await orch.complete(prompt: "test", scope: .global)
        #expect(response.text == "fallback response")
    }

    @Test("selectedText is passed through to the request")
    func selectedTextPassthrough() async throws {
        let mock = MockLLMProvider(capabilities: [], responses: ["ok"])
        let (orch, _) = await makeOrchestrator(provider: mock)

        _ = try await orch.complete(
            prompt: "explain this",
            selectedText: "func foo() {}",
            scope: .global
        )

        let calls = await mock.completeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.selectedText == "func foo() {}")
    }

    @Test("availableProviders returns only available ones")
    func availableProviders() async throws {
        let search = MockSearchService()
        let repo = MockDocumentRepository()
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let orch = LLMOrchestrator(
            contextBuilder: contextBuilder,
            defaultProviderID: .anthropic,
            vaultName: "TestVault"
        )

        let available = MockLLMProvider(id: .anthropic, isAvailable: true)
        let unavailable = MockLLMProvider(id: .openAI, isAvailable: false)
        await orch.registerProvider(available)
        await orch.registerProvider(unavailable)

        let providers = await orch.availableProviders()
        #expect(providers.contains(.anthropic))
        #expect(!providers.contains(.openAI))
    }
}
