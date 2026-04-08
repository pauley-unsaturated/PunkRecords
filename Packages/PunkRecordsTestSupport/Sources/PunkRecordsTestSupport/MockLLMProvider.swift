import Foundation
import PunkRecordsCore

/// Configurable mock LLM provider for testing.
public actor MockLLMProvider: LLMProvider {
    public nonisolated let id: LLMProviderID
    public nonisolated let displayName: String
    public nonisolated let capabilities: LLMCapabilities
    public let maxContextTokens: Int

    public var responses: [String]
    public var isAvailableValue: Bool
    public var latency: TimeInterval
    public private(set) var completeCalls: [LLMRequest] = []
    public private(set) var streamCalls: [LLMRequest] = []

    public init(
        id: LLMProviderID = .anthropic,
        displayName: String = "Mock Provider",
        capabilities: LLMCapabilities = [.streaming],
        maxContextTokens: Int = 128_000,
        responses: [String] = ["Mock response"],
        isAvailable: Bool = true,
        latency: TimeInterval = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.maxContextTokens = maxContextTokens
        self.responses = responses
        self.isAvailableValue = isAvailable
        self.latency = latency
    }

    public func isAvailable() async -> Bool {
        isAvailableValue
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        completeCalls.append(request)
        if latency > 0 {
            try await Task.sleep(for: .seconds(latency))
        }
        let text = responses.isEmpty ? "Mock response" : responses.removeFirst()
        return LLMResponse(text: text, providerID: id)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        let responseText = responses.isEmpty ? "Mock response" : responses[0]
        let delay = latency

        // Record call (can't mutate here since we return a non-isolated stream)
        let providerID = id
        _ = providerID // suppress unused warning

        return AsyncThrowingStream { continuation in
            Task {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                // Stream word by word
                let words = responseText.split(separator: " ")
                for (i, word) in words.enumerated() {
                    let token = (i > 0 ? " " : "") + word
                    continuation.yield(String(token))
                }
                continuation.finish()
            }
        }
    }
}
