import Foundation

/// Outcome of probing a local LLM server: whether it answered, which models it
/// offers, and an error string to show if it didn't.
public struct ProviderValidationResult: Sendable, Equatable {
    public let isReachable: Bool
    public let models: [LocalModel]
    public let errorMessage: String?

    public init(isReachable: Bool, models: [LocalModel] = [], errorMessage: String? = nil) {
        self.isReachable = isReachable
        self.models = models
        self.errorMessage = errorMessage
    }

    public static func unreachable(_ message: String) -> ProviderValidationResult {
        ProviderValidationResult(isReachable: false, models: [], errorMessage: message)
    }
}
