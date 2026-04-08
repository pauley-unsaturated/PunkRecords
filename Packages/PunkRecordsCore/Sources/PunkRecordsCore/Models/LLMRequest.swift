import Foundation

public struct LLMRequest: Sendable {
    public var userPrompt: String
    public var systemPrompt: String?
    public var contextDocuments: [DocumentExcerpt]
    public var selectedText: String?
    public var streamResponse: Bool

    public init(
        userPrompt: String,
        systemPrompt: String? = nil,
        contextDocuments: [DocumentExcerpt] = [],
        selectedText: String? = nil,
        streamResponse: Bool = true
    ) {
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.contextDocuments = contextDocuments
        self.selectedText = selectedText
        self.streamResponse = streamResponse
    }
}
