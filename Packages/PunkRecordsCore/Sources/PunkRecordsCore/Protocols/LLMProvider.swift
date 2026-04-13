import Foundation

public protocol LLMProvider: Actor {
    nonisolated var id: LLMProviderID { get }
    nonisolated var displayName: String { get }
    nonisolated var capabilities: LLMCapabilities { get }
    var maxContextTokens: Int { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error>
    func isAvailable() async -> Bool

    /// Complete a request that may include tool definitions. Providers that support
    /// tool use should override this to handle tool_use content blocks.
    func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse
}

public extension LLMProvider {
    func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        let response = try await complete(request)
        return LLMToolResponse(
            contentBlocks: [.text(response.text)],
            stopReason: .endTurn,
            usage: response.usage
        )
    }
}
