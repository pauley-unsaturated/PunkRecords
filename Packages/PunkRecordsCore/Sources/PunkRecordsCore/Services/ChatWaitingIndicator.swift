import Foundation

/// Pure decision for whether the chat panel should show the animated
/// "waiting for response" bubble in place of the next assistant turn.
///
/// The indicator covers two gaps in a turn's timeline:
///  - between send and the model's first streamed text token, and
///  - between a tool-call chip (``ChatTurnReducer`` breaks the assistant
///    bubble around tool calls) and the narration that follows it.
///
/// It is derived purely from ``ChatSessionController``'s `isStreaming` flag
/// and the live transcript's trailing role, so the SwiftUI layer only has to
/// call ``shouldShow(isStreaming:messages:)`` — no view-local state, no
/// timers, nothing to desync from the reducer.
public enum ChatWaitingIndicator {

    /// - Parameters:
    ///   - isStreaming: Whether a turn is currently in flight (mirrors
    ///     `ChatSessionController.isStreaming`).
    ///   - messages: The live transcript, already folded by ``ChatTurnReducer``.
    /// - Returns: `true` when the trailing row is a user prompt or a tool chip
    ///   with no assistant text after it yet; `false` once assistant text has
    ///   started streaming (or the transcript is empty, or the turn ended).
    public static func shouldShow(isStreaming: Bool, messages: [ChatMessage]) -> Bool {
        guard isStreaming else { return false }
        guard let last = messages.last else { return true }

        switch last.role {
        case .user, .tool:
            return true
        case .assistant:
            return false
        }
    }
}
