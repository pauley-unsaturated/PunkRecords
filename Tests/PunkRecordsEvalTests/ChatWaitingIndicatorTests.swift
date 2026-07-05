import Testing
import Foundation
@testable import PunkRecordsCore

/// Unit tests for ``ChatWaitingIndicator`` — the pure decision of whether the
/// chat panel should show the animated "waiting for response" bubble in place
/// of the next assistant turn. Sits alongside ``ChatTurnReducerTests`` since
/// the indicator's inputs (``ChatSessionController.isStreaming`` and the
/// transcript ``ChatTurnReducer`` produces) come from the same event fold.
@Suite("ChatWaitingIndicator show/hide decision")
struct ChatWaitingIndicatorTests {

    private func userMessage(_ text: String = "hi") -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    private func assistantMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text)
    }

    private func toolMessage(name: String = "vault_search", inFlight: Bool) -> ChatMessage {
        var info = ToolCallInfo(name: name, arguments: "{}")
        info.isInFlight = inFlight
        return ChatMessage(role: .tool, content: "", toolCall: info)
    }

    @Test("Not streaming never shows the indicator, regardless of transcript")
    func notStreamingHidesIndicator() {
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: false, messages: []) == false)
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: false, messages: [userMessage()]) == false)
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: false, messages: [toolMessage(inFlight: true)]) == false)
    }

    @Test("Empty turn just sent — user message with no reply yet shows the indicator")
    func freshlySentTurnShowsIndicator() {
        let messages = [userMessage("Explain Swift concurrency")]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == true)
    }

    @Test("Streaming with no messages at all still shows the indicator")
    func streamingWithEmptyTranscriptShowsIndicator() {
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: []) == true)
    }

    @Test("Assistant text streaming (growing bubble) hides the indicator")
    func streamingAssistantTextHidesIndicator() {
        var messages = [userMessage()]
        messages.append(assistantMessage("Hello"))
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == false)

        // Growing further still hides it.
        messages[messages.count - 1].content += ", world"
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == false)
    }

    @Test("Tool chip just added, no following text — indicator shows")
    func toolChipInFlightShowsIndicator() {
        let messages: [ChatMessage] = [
            userMessage(),
            assistantMessage("Let me search first."),
            toolMessage(inFlight: true),
        ]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == true)
    }

    @Test("Tool chip completed, no following text yet — indicator still shows")
    func toolChipCompletedShowsIndicator() {
        let messages: [ChatMessage] = [
            userMessage(),
            assistantMessage("Let me search first."),
            toolMessage(inFlight: false),
        ]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == true)
    }

    @Test("Text after a tool chip hides the indicator again")
    func textAfterToolChipHidesIndicator() {
        let messages: [ChatMessage] = [
            userMessage(),
            assistantMessage("Let me search first."),
            toolMessage(inFlight: false),
            assistantMessage("Here is the answer."),
        ]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == false)
    }

    @Test("Turn ended — isStreaming false hides the indicator even with a trailing tool chip")
    func turnEndedHidesIndicator() {
        let messages: [ChatMessage] = [
            userMessage(),
            toolMessage(inFlight: false),
        ]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: false, messages: messages) == false)
    }

    @Test("An in-stream error appends an assistant bubble, hiding the indicator")
    func errorSurfacedHidesIndicator() {
        let messages: [ChatMessage] = [
            userMessage(),
            assistantMessage("*Agent error: boom*"),
        ]
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: true, messages: messages) == false)
        #expect(ChatWaitingIndicator.shouldShow(isStreaming: false, messages: messages) == false)
    }
}
