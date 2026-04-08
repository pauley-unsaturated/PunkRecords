import Foundation
import PunkRecordsCore

/// Apple on-device inference via FoundationModels framework.
/// Gated behind @available(macOS 26, *).
public actor FoundationModelsProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.foundationModels
    public nonisolated let displayName = "Apple Intelligence"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .onDevice]
    public var maxContextTokens: Int { 4_000 } // Conservative estimate for on-device

    public init() {}

    public func isAvailable() async -> Bool {
        guard #available(macOS 26, *) else { return false }
        // FoundationModels availability check would go here
        // For now, return false since we can't compile against it on macOS 15
        return false
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard #available(macOS 26, *) else {
            throw LLMError.providerUnavailable(.foundationModels)
        }
        // TODO: Implement when building on macOS 26 SDK
        throw LLMError.providerUnavailable(.foundationModels)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.providerUnavailable(.foundationModels))
        }
    }
}
