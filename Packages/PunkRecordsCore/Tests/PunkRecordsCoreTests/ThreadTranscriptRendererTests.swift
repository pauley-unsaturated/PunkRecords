import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("ThreadTranscriptRenderer — compact, budget-aware transcript rendering")
struct ThreadTranscriptRendererTests {

    private func context(label: String) -> MessageContext {
        MessageContext(
            scope: .global,
            scopeLabel: label,
            currentDocumentID: nil,
            selection: nil,
            variantID: "terse-v1",
            userPrompt: "prompt"
        )
    }

    // MARK: - Roles / markers / annotations

    @Test("Roles render as prefixed lines and the title becomes a heading")
    func rolesAndTitle() {
        let messages = [
            ChatMessage(role: .user, content: "what is reverb?"),
            ChatMessage(role: .assistant, content: "an echo effect"),
        ]
        let out = ThreadTranscriptRenderer.render(title: "Reverb chat", messages: messages)
        #expect(out.contains("# Reverb chat"))
        #expect(out.contains("User: what is reverb?"))
        #expect(out.contains("Assistant: an echo effect"))
    }

    @Test("Tool messages collapse to a one-line marker with status and output")
    func toolMarkers() {
        let done = ChatMessage(
            role: .tool, content: "",
            toolCall: ToolCallInfo(name: "vault_search", arguments: "{}", output: "3 hits\nmore", isError: false, isInFlight: false)
        )
        let inFlight = ChatMessage(
            role: .tool, content: "",
            toolCall: ToolCallInfo(name: "read_document", arguments: "{}", output: "", isError: false, isInFlight: true)
        )
        let failed = ChatMessage(
            role: .tool, content: "",
            toolCall: ToolCallInfo(name: "create_note", arguments: "{}", output: "boom", isError: true, isInFlight: false)
        )
        #expect(ThreadTranscriptRenderer.toolMarker(done) == "[tool: vault_search] → 3 hits more")
        #expect(ThreadTranscriptRenderer.toolMarker(inFlight) == "[tool: read_document (in progress)]")
        #expect(ThreadTranscriptRenderer.toolMarker(failed) == "[tool: create_note (error)] → boom")
    }

    @Test("Per-message note-context is annotated when present")
    func contextAnnotation() {
        let messages = [
            ChatMessage(role: .assistant, content: "here you go", context: context(label: "My Note")),
        ]
        let out = ThreadTranscriptRenderer.render(title: nil, messages: messages)
        #expect(out.contains("Assistant (re: My Note): here you go"))
    }

    @Test("Tool markers can be excluded via options")
    func excludeToolMarkers() {
        let messages = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .tool, content: "", toolCall: ToolCallInfo(name: "vault_search", arguments: "{}")),
            ChatMessage(role: .assistant, content: "hello"),
        ]
        let out = ThreadTranscriptRenderer.render(
            title: nil, messages: messages,
            options: .init(includeToolCalls: false)
        )
        #expect(!out.contains("[tool:"))
        #expect(out.contains("User: hi"))
        #expect(out.contains("Assistant: hello"))
    }

    // MARK: - Truncation

    @Test("Full transcript within budget is returned untouched")
    func withinBudgetUntouchedByElision() {
        let messages = [
            ChatMessage(role: .user, content: "short one"),
            ChatMessage(role: .assistant, content: "short reply"),
        ]
        let out = ThreadTranscriptRenderer.render(title: nil, messages: messages, budget: 10_000)
        #expect(!out.contains("elided"))
        #expect(out == "User: short one\nAssistant: short reply")
    }

    @Test("Over-budget transcript keeps head + tail and elides the middle")
    func headTailElision() {
        // Six chunky messages (~90 tokens each). A 230-token budget admits the
        // first and last with a marker between them; the inner four are elided.
        let filler = String(repeating: "alpha ", count: 60)
        let messages = (0..<6).map { i in
            ChatMessage(role: i % 2 == 0 ? .user : .assistant, content: "MSG\(i) \(filler)")
        }
        let budget = 230
        let out = ThreadTranscriptRenderer.render(title: nil, messages: messages, budget: budget)

        #expect(out.contains("elided"))
        // Opening and most-recent turns survive.
        #expect(out.contains("MSG0"))
        #expect(out.contains("MSG5"))
        // The deep middle is dropped.
        #expect(!out.contains("MSG2"))
        #expect(!out.contains("MSG3"))
        // Result honors the budget.
        #expect(TokenEstimator.estimateTokens(in: out) <= budget)
    }

    @Test("Elision marker pluralizes on count")
    func elisionMarkerText() {
        #expect(ThreadTranscriptRenderer.elisionMarker(elidedCount: 1) == "… [1 message elided] …")
        #expect(ThreadTranscriptRenderer.elisionMarker(elidedCount: 4) == "… [4 messages elided] …")
    }
}
