import Foundation

/// One row in the chat transcript: a user prompt, an assistant response, or a
/// tool-call chip. Pure value type so the transcript, the event→message
/// reducer, and their tests live in Core without importing SwiftUI/Infra.
public struct ChatMessage: Identifiable, Sendable {
    public let id = UUID()
    public let role: Role
    public var content: String
    public var attachments: [ChatAttachmentMetadata]
    public var attachmentTranscript: String
    public let timestamp: Date = Date()
    /// For assistant messages: snapshot of what the user did when submitting the
    /// triggering prompt. Used by the "Report Issue" flow to reconstruct context.
    public var context: MessageContext?
    /// Populated when role == .tool - the agent tool invocation this row represents.
    public var toolCall: ToolCallInfo?
    /// For assistant messages: which provider produced this output. Drives the
    /// "via Claude / GPT / Apple" attribution chip and lets future "rerun with
    /// a different model" actions know what to switch from.
    public var providerID: LLMProviderID?

    public enum Role: Sendable {
        case user, assistant, tool

        public var rawValue: String {
            switch self {
            case .user: "user"
            case .assistant: "assistant"
            case .tool: "tool"
            }
        }
    }

    public init(
        role: Role,
        content: String,
        attachments: [ChatAttachmentMetadata] = [],
        attachmentTranscript: String = "",
        context: MessageContext? = nil,
        toolCall: ToolCallInfo? = nil,
        providerID: LLMProviderID? = nil
    ) {
        self.role = role
        self.content = content
        self.attachments = attachments
        self.attachmentTranscript = attachmentTranscript
        self.context = context
        self.toolCall = toolCall
        self.providerID = providerID
    }
}
