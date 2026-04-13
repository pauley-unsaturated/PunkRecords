import Foundation

public struct LLMRequest: Sendable {
    public var userPrompt: String
    public var systemPrompt: String?
    public var contextDocuments: [DocumentExcerpt]
    public var selectedText: String?
    public var streamResponse: Bool
    public var tools: [ToolDefinition]?
    public var messages: [ConversationMessage]?

    public init(
        userPrompt: String,
        systemPrompt: String? = nil,
        contextDocuments: [DocumentExcerpt] = [],
        selectedText: String? = nil,
        streamResponse: Bool = true,
        tools: [ToolDefinition]? = nil,
        messages: [ConversationMessage]? = nil
    ) {
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.contextDocuments = contextDocuments
        self.selectedText = selectedText
        self.streamResponse = streamResponse
        self.tools = tools
        self.messages = messages
    }
}
