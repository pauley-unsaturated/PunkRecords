import Foundation

/// Pure fold from the agent's ``AgentEvent`` stream onto the chat transcript.
///
/// `SessionAgentRunner` owns the agentic loop and emits ``AgentEvent``s; this
/// reducer is the *only* place those events become ``ChatMessage`` rows, so the
/// mapping (tool-call chip added, assistant text accumulated, usage captured,
/// error surfaced) is unit-testable without SwiftUI: feed a scripted sequence
/// of events and assert the resulting `messages` transitions.
///
/// It is deliberately value-typed and side-effect free — the caller supplies the
/// transcript (`inout [ChatMessage]`) and a small carry-over ``State`` and gets
/// back a fully deterministic mutation. Persistence, streaming, and provider
/// resolution stay in the controller; this stays pure.
public enum ChatTurnReducer {

    /// Carry-over state threaded across the events of a single turn.
    public struct State {
        /// Index of the assistant text bubble currently being appended to.
        /// `nil` after a tool call, which forces the next `.textToken` to start a
        /// fresh bubble — so tool calls visually break up the assistant's
        /// narration, exactly as the pre-refactor view did.
        var currentAssistantIndex: Int?

        /// Token accounting from the most recent `.turnEnd`, when the producer
        /// supplied it. AnyLanguageModel reports no real usage, so this is the
        /// runner's ``TokenEstimator`` heuristic; `nil` until a round ends with
        /// usage. Captured for observability/metrics — the transcript rows are
        /// unaffected.
        public fileprivate(set) var lastUsage: TokenUsage?

        public init() {}
    }

    /// Fold a single ``AgentEvent`` into the transcript.
    ///
    /// - Parameters:
    ///   - event: The event emitted by `SessionAgentRunner`.
    ///   - messages: The live transcript; assistant text and tool chips are
    ///     appended/updated in place.
    ///   - state: Per-turn carry-over (current bubble index, last usage).
    ///   - context: Submission-time context stamped onto assistant/error rows so
    ///     "Report Issue" can reconstruct the turn. Tool rows carry no context.
    ///   - providerID: Provider that produced the turn, stamped onto assistant
    ///     text rows to drive the "via Claude / GPT / Apple" attribution chip.
    public static func apply(
        _ event: AgentEvent,
        to messages: inout [ChatMessage],
        state: inout State,
        context: MessageContext?,
        providerID: LLMProviderID?
    ) {
        switch event {
        case .textToken(let token):
            if let idx = state.currentAssistantIndex, messages.indices.contains(idx) {
                messages[idx].content += token
            } else {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: token,
                    context: context,
                    providerID: providerID
                ))
                state.currentAssistantIndex = messages.count - 1
            }

        case .toolStart(let name, let args):
            let info = ToolCallInfo(name: name, arguments: args)
            messages.append(ChatMessage(role: .tool, content: "", toolCall: info))
            state.currentAssistantIndex = nil

        case .toolEnd(let name, let result):
            if let idx = messages.lastIndex(where: {
                $0.role == .tool && $0.toolCall?.name == name && $0.toolCall?.isInFlight == true
            }), var info = messages[idx].toolCall {
                info.output = result.content
                info.isError = result.isError
                info.isInFlight = false
                messages[idx].toolCall = info
            }

        case .error(let err):
            messages.append(ChatMessage(role: .assistant, content: "*Agent error: \(err)*", context: context))
            state.currentAssistantIndex = nil

        case .turnEnd(_, let usage):
            if let usage { state.lastUsage = usage }

        case .done, .agentStart, .turnStart:
            break
        }
    }
}
