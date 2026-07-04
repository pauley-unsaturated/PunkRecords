import Foundation
import PunkRecordsCore
import PunkRecordsInfra

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    var attachments: [ChatAttachmentMetadata] = []
    var attachmentTranscript = ""
    let timestamp: Date = Date()
    /// For assistant messages: snapshot of what the user did when submitting the
    /// triggering prompt. Used by the "Report Issue" flow to reconstruct context.
    var context: MessageContext?
    /// Populated when role == .tool - the agent tool invocation this row represents.
    var toolCall: ToolCallInfo?
    /// For assistant messages: which provider produced this output. Drives the
    /// "via Claude / GPT / Apple" attribution chip and lets future "rerun with
    /// a different model" actions know what to switch from.
    var providerID: LLMProviderID?

    enum Role {
        case user, assistant, tool

        var rawValue: String {
            switch self {
            case .user: "user"
            case .assistant: "assistant"
            case .tool: "tool"
            }
        }
    }
}
