import Foundation
import PunkRecordsCore

/// Mock LLM provider that returns scripted LLMToolResponse values in sequence.
/// Used for deterministic agent loop testing where you pre-define the LLM's behavior.
public actor ScriptedProvider: LLMProvider {
    public nonisolated let id: LLMProviderID
    public nonisolated let displayName = "Scripted Provider"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext, .functionCalls]
    public let maxContextTokens: Int

    private var scriptedResponses: [LLMToolResponse]
    public private(set) var requestLog: [LLMRequest] = []

    public init(
        id: LLMProviderID = .anthropic,
        maxContextTokens: Int = 128_000,
        script: [LLMToolResponse]
    ) {
        self.id = id
        self.maxContextTokens = maxContextTokens
        self.scriptedResponses = script
    }

    public func isAvailable() async -> Bool { true }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        requestLog.append(request)
        let response = nextResponse()
        return LLMResponse(text: response.textContent, providerID: id, usage: response.usage)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        let text = nextResponse().textContent
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    public func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        requestLog.append(request)
        return nextResponse()
    }

    private func nextResponse() -> LLMToolResponse {
        guard !scriptedResponses.isEmpty else {
            return LLMToolResponse(contentBlocks: [.text("Script exhausted")], stopReason: .endTurn, usage: nil)
        }
        return scriptedResponses.removeFirst()
    }
}
