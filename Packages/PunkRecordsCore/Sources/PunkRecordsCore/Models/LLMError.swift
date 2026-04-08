import Foundation

public enum LLMError: Error, Sendable {
    case providerUnavailable(LLMProviderID)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case providerError(String)
    case timeout
    case contextTooLarge(requested: Int, maximum: Int)
    case noProvidersConfigured
}
