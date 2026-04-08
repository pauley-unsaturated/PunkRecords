import Foundation

public protocol LLMProvider: Actor {
    nonisolated var id: LLMProviderID { get }
    nonisolated var displayName: String { get }
    nonisolated var capabilities: LLMCapabilities { get }
    var maxContextTokens: Int { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error>
    func isAvailable() async -> Bool
}
