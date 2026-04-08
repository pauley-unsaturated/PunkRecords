import Foundation

public enum LLMStreamEvent: Sendable {
    case token(String)
    case citation(DocumentID, excerpt: String)
    case done(LLMResponse)
    case error(any Error)
}
