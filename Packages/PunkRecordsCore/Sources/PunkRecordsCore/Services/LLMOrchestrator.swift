import Foundation

/// Routes LLM queries to the appropriate provider, assembles context, and streams responses.
public actor LLMOrchestrator {
    private var providers: [LLMProviderID: any LLMProvider] = [:]
    private let contextBuilder: ContextBuilder
    private var defaultProviderID: LLMProviderID
    private var vaultName: String

    public init(
        contextBuilder: ContextBuilder,
        defaultProviderID: LLMProviderID,
        vaultName: String
    ) {
        self.contextBuilder = contextBuilder
        self.defaultProviderID = defaultProviderID
        self.vaultName = vaultName
    }

    public func registerProvider(_ provider: any LLMProvider) async {
        providers[provider.id] = provider
    }

    public func setDefaultProvider(_ id: LLMProviderID) {
        defaultProviderID = id
    }

    public func availableProviders() async -> [LLMProviderID] {
        var available: [LLMProviderID] = []
        for (id, provider) in providers {
            if await provider.isAvailable() {
                available.append(id)
            }
        }
        return available
    }

    /// Main entry point: ask a question with KB context.
    public func ask(
        prompt: String,
        selectedText: String? = nil,
        scope: QueryScope,
        currentDocumentID: DocumentID? = nil,
        provider providerID: LLMProviderID? = nil
    ) async throws -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let provider = try await resolveProvider(providerID)
        let maxTokens = await provider.maxContextTokens

        let (systemPrompt, excerpts) = try await contextBuilder.buildContext(
            prompt: prompt,
            scope: scope,
            currentDocumentID: currentDocumentID,
            maxTokens: maxTokens,
            vaultName: vaultName
        )

        let request = LLMRequest(
            userPrompt: prompt,
            systemPrompt: systemPrompt,
            contextDocuments: excerpts,
            selectedText: selectedText,
            streamResponse: true
        )

        if provider.capabilities.contains(.streaming) {
            return await streamFromProvider(provider, request: request, excerpts: excerpts)
        } else {
            return completeFromProvider(provider, request: request, excerpts: excerpts)
        }
    }

    /// Non-streaming complete, wrapped in an AsyncThrowingStream for uniform API.
    public func complete(
        prompt: String,
        selectedText: String? = nil,
        scope: QueryScope,
        currentDocumentID: DocumentID? = nil,
        provider providerID: LLMProviderID? = nil
    ) async throws -> LLMResponse {
        let provider = try await resolveProvider(providerID)
        let maxTokens = await provider.maxContextTokens

        let (systemPrompt, excerpts) = try await contextBuilder.buildContext(
            prompt: prompt,
            scope: scope,
            currentDocumentID: currentDocumentID,
            maxTokens: maxTokens,
            vaultName: vaultName
        )

        let request = LLMRequest(
            userPrompt: prompt,
            systemPrompt: systemPrompt,
            contextDocuments: excerpts,
            selectedText: selectedText,
            streamResponse: false
        )

        return try await provider.complete(request)
    }

    // MARK: - Private

    private func resolveProvider(_ requestedID: LLMProviderID?) async throws -> any LLMProvider {
        let targetID = requestedID ?? defaultProviderID

        if let provider = providers[targetID], await provider.isAvailable() {
            return provider
        }

        // Fallback: try other providers
        for (_, provider) in providers {
            if await provider.isAvailable() {
                return provider
            }
        }

        throw LLMError.noProvidersConfigured
    }

    private func streamFromProvider(
        _ provider: any LLMProvider,
        request: LLMRequest,
        excerpts: [DocumentExcerpt]
    ) async -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let providerID = provider.id
        let tokenStream = await provider.stream(request)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var fullText = ""
                do {
                    for try await token in tokenStream {
                        fullText += token
                        continuation.yield(.token(token))
                    }
                    let response = LLMResponse(
                        text: fullText,
                        providerID: providerID,
                        usedDocuments: excerpts.map(\.documentID)
                    )
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func completeFromProvider(
        _ provider: any LLMProvider,
        request: LLMRequest,
        excerpts: [DocumentExcerpt]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await provider.complete(request)
                    continuation.yield(.token(response.text))
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
