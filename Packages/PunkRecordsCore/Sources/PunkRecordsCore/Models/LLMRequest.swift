import Foundation

public struct LLMRequest: Sendable {
    public var userPrompt: String
    public var systemPrompt: String?
    public var contextDocuments: [DocumentExcerpt]
    public var selectedText: String?
    public var streamResponse: Bool
    public var tools: [ToolDefinition]?
    public var messages: [ConversationMessage]?
    /// Provider-managed tools that run on the LLM provider's infrastructure
    /// (e.g. Anthropic's native web_search). Providers that don't support
    /// these silently ignore the field.
    public var serverTools: [ServerToolConfig]?

    public init(
        userPrompt: String,
        systemPrompt: String? = nil,
        contextDocuments: [DocumentExcerpt] = [],
        selectedText: String? = nil,
        streamResponse: Bool = true,
        tools: [ToolDefinition]? = nil,
        messages: [ConversationMessage]? = nil,
        serverTools: [ServerToolConfig]? = nil
    ) {
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.contextDocuments = contextDocuments
        self.selectedText = selectedText
        self.streamResponse = streamResponse
        self.tools = tools
        self.messages = messages
        self.serverTools = serverTools
    }
}

/// Configuration for a provider-managed tool that runs server-side.
public enum ServerToolConfig: Sendable, Equatable {
    /// Anthropic's native web search tool. `maxUses` caps how many search calls
    /// the model can make per turn; pass nil for the provider default.
    case webSearch(maxUses: Int?)
}
