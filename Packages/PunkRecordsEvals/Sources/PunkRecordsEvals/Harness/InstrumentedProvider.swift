import Foundation
import PunkRecordsCore

/// Wraps any LLMProvider to capture per-call metrics (tokens, latency, cache data).
/// Use with live API providers to measure real performance.
public actor InstrumentedProvider: LLMProvider {
    private let wrapped: any LLMProvider
    private let collector: MetricsCollector
    private let _maxContextTokens: Int

    public nonisolated var id: LLMProviderID { wrapped.id }
    public nonisolated var displayName: String { wrapped.displayName }
    public nonisolated var capabilities: LLMCapabilities { wrapped.capabilities }
    public var maxContextTokens: Int { _maxContextTokens }

    /// Create an instrumented wrapper. Must be called with `await` to read the wrapped provider's context window.
    public init(wrapping provider: any LLMProvider, collector: MetricsCollector) async {
        self.wrapped = provider
        self.collector = collector
        self._maxContextTokens = await provider.maxContextTokens
    }

    public func isAvailable() async -> Bool {
        await wrapped.isAvailable()
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await wrapped.complete(request)
        await collector.recordTurnTokens(TokenMetrics(from: response.usage))
        return response
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        await wrapped.stream(request)
    }

    public func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        let response = try await wrapped.completeWithTools(request)
        await collector.recordTurnTokens(TokenMetrics(from: response.usage))
        return response
    }
}
