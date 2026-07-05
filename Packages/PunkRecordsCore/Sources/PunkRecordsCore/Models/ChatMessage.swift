import Foundation

/// One row in the chat transcript: a user prompt, an assistant response, or a
/// tool-call chip. Pure value type so the transcript, the event→message
/// reducer, and their tests live in Core without importing SwiftUI/Infra.
///
/// `Codable` so a full conversation persists losslessly inside a ``ChatThread``
/// — including each turn's ``context`` (which note the turn was about) and any
/// ``toolCall`` chip. `id` and `timestamp` are decoded (not regenerated) so a
/// reloaded thread keeps stable message identities, which a follow-up forking
/// feature keys off via ``ChatThread/forkedAtMessageID``.
public struct ChatMessage: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let role: Role
    public var content: String
    public var attachments: [ChatAttachmentMetadata]
    public var attachmentTranscript: String
    public let timestamp: Date
    /// For assistant messages: snapshot of what the user did when submitting the
    /// triggering prompt. Used by the "Report Issue" flow to reconstruct context
    /// and (once persisted) so a reloaded thread knows which note each turn was
    /// about.
    public var context: MessageContext?
    /// Populated when role == .tool - the agent tool invocation this row represents.
    public var toolCall: ToolCallInfo?
    /// For assistant messages: which provider produced this output. Drives the
    /// "via Claude / GPT / Apple" attribution chip and lets future "rerun with
    /// a different model" actions know what to switch from.
    public var providerID: LLMProviderID?

    public enum Role: String, Sendable, Codable, Equatable {
        case user, assistant, tool
    }

    public init(
        role: Role,
        content: String,
        attachments: [ChatAttachmentMetadata] = [],
        attachmentTranscript: String = "",
        context: MessageContext? = nil,
        toolCall: ToolCallInfo? = nil,
        providerID: LLMProviderID? = nil,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.attachmentTranscript = attachmentTranscript
        self.context = context
        self.toolCall = toolCall
        self.providerID = providerID
        self.timestamp = timestamp
    }
}
