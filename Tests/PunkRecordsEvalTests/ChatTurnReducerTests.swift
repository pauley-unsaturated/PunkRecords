import Testing
import Foundation
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport

/// Unit tests for ``ChatTurnReducer`` — the pure fold from the agent's
/// ``AgentEvent`` stream onto the chat transcript, extracted out of
/// `LLMChatPanel` so the event→message mapping is testable without SwiftUI.
///
/// Two layers of coverage:
///  1. Hand-built event sequences pinned against exact transcript transitions
///     (tool chip added/completed, assistant text accumulated, usage captured,
///     error surfaced).
///  2. An end-to-end pass driving a real `SessionAgentRunner` over a
///     `ScriptedLanguageModel`, feeding its emitted events through the reducer —
///     the same production plumbing the chat panel runs, model canned.
@Suite("ChatTurnReducer event→message mapping")
struct ChatTurnReducerTests {

    private func sampleContext() -> MessageContext {
        MessageContext(
            scope: .global,
            scopeLabel: "KB-wide",
            currentDocumentID: nil,
            selection: nil,
            variantID: "terse-v1",
            userPrompt: "hi"
        )
    }

    /// Fold a whole event sequence through the reducer and return the transcript
    /// plus the final carry-over state.
    private func reduce(
        _ events: [AgentEvent],
        initial: [ChatMessage] = [],
        context: MessageContext? = nil,
        providerID: LLMProviderID? = nil
    ) -> (messages: [ChatMessage], state: ChatTurnReducer.State) {
        var messages = initial
        var state = ChatTurnReducer.State()
        for event in events {
            ChatTurnReducer.apply(event, to: &messages, state: &state, context: context, providerID: providerID)
        }
        return (messages, state)
    }

    // MARK: - Assistant text

    @Test("Text tokens accumulate into a single assistant bubble")
    func textTokensAccumulate() {
        let (messages, _) = reduce(
            [
                .agentStart,
                .turnStart(turnIndex: 0),
                .textToken("Hello"),
                .textToken(", world"),
                .turnEnd(turnIndex: 0, usage: nil),
                .done(finalText: "Hello, world"),
            ],
            providerID: .anthropic
        )

        #expect(messages.count == 1)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content == "Hello, world")
        #expect(messages[0].providerID == .anthropic)
    }

    @Test("Assistant bubble carries submission context and provider attribution")
    func assistantCarriesContextAndProvider() {
        let ctx = sampleContext()
        let (messages, _) = reduce([.textToken("Answer")], context: ctx, providerID: .openAI)

        #expect(messages.count == 1)
        #expect(messages[0].context?.userPrompt == "hi")
        #expect(messages[0].providerID == .openAI)
    }

    // MARK: - Tool chips

    @Test("toolStart adds an in-flight tool chip; toolEnd completes it")
    func toolChipLifecycle() {
        let (messages, _) = reduce([
            .toolStart(name: "vault_search", arguments: #"{"query":"swift"}"#),
            .toolEnd(name: "vault_search", result: ToolResult(content: "1 result", isError: false)),
        ])

        #expect(messages.count == 1)
        let msg = messages[0]
        #expect(msg.role == .tool)
        #expect(msg.toolCall?.name == "vault_search")
        #expect(msg.toolCall?.arguments == #"{"query":"swift"}"#)
        #expect(msg.toolCall?.isInFlight == false)
        #expect(msg.toolCall?.output == "1 result")
        #expect(msg.toolCall?.isError == false)
    }

    @Test("A failing tool round-trips isError through the chip")
    func toolErrorSurfaced() {
        let (messages, _) = reduce([
            .toolStart(name: "read_document", arguments: #"{"path":"Missing.md"}"#),
            .toolEnd(name: "read_document", result: ToolResult(content: "Error: not found", isError: true)),
        ])

        #expect(messages[0].toolCall?.isError == true)
        #expect(messages[0].toolCall?.output == "Error: not found")
        #expect(messages[0].toolCall?.isInFlight == false)
    }

    @Test("A tool call breaks the assistant narration into separate bubbles")
    func toolBreaksAssistantBubbles() {
        // Narration text, then a tool round, then the final answer — the answer
        // must land in a NEW assistant bubble, not appended to the narration.
        let (messages, _) = reduce([
            .textToken("Let me search first."),
            .toolStart(name: "vault_search", arguments: "{}"),
            .toolEnd(name: "vault_search", result: ToolResult(content: "found")),
            .textToken("Here is the answer."),
        ])

        #expect(messages.count == 3)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content == "Let me search first.")
        #expect(messages[1].role == .tool)
        #expect(messages[2].role == .assistant)
        #expect(messages[2].content == "Here is the answer.")
    }

    @Test("toolEnd targets the matching in-flight chip when several are open")
    func toolEndMatchesByName() {
        let (messages, _) = reduce([
            .toolStart(name: "vault_search", arguments: "{}"),
            .toolStart(name: "read_document", arguments: "{}"),
            .toolEnd(name: "read_document", result: ToolResult(content: "doc body")),
        ])

        #expect(messages.count == 2)
        // vault_search remains in flight; read_document completed.
        #expect(messages[0].toolCall?.name == "vault_search")
        #expect(messages[0].toolCall?.isInFlight == true)
        #expect(messages[1].toolCall?.name == "read_document")
        #expect(messages[1].toolCall?.isInFlight == false)
        #expect(messages[1].toolCall?.output == "doc body")
    }

    // MARK: - Usage capture

    @Test("turnEnd usage is captured into reducer state without adding rows")
    func usageCaptured() {
        let usage = TokenUsage(promptTokens: 120, completionTokens: 30)
        let (messages, state) = reduce([
            .textToken("Answer"),
            .turnEnd(turnIndex: 0, usage: usage),
        ])

        #expect(messages.count == 1) // no extra row for the usage event
        #expect(state.lastUsage?.promptTokens == 120)
        #expect(state.lastUsage?.completionTokens == 30)
    }

    @Test("The most recent non-nil turn usage wins")
    func lastUsageWins() {
        let (_, state) = reduce([
            .turnEnd(turnIndex: 0, usage: TokenUsage(promptTokens: 10, completionTokens: 5)),
            .turnEnd(turnIndex: 1, usage: nil),
            .turnEnd(turnIndex: 2, usage: TokenUsage(promptTokens: 99, completionTokens: 7)),
        ])

        #expect(state.lastUsage?.promptTokens == 99)
    }

    // MARK: - Errors

    @Test("An in-stream error surfaces as an assistant bubble")
    func errorSurfaced() {
        let ctx = sampleContext()
        let (messages, _) = reduce([.error(.providerError("boom"))], context: ctx)

        #expect(messages.count == 1)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content.contains("Agent error"))
        #expect(messages[0].content.contains("boom"))
        #expect(messages[0].context?.userPrompt == "hi")
    }

    @Test("After an error, subsequent text starts a fresh bubble")
    func errorResetsCurrentBubble() {
        let (messages, _) = reduce([
            .textToken("partial"),
            .error(.maxIterationsExceeded(8)),
            .textToken("recovered"),
        ])

        #expect(messages.count == 3)
        #expect(messages[0].content == "partial")
        #expect(messages[1].content.contains("Agent error"))
        #expect(messages[2].content == "recovered")
    }

    // MARK: - End-to-end through the real runner

    @Test("Real SessionAgentRunner events fold into a tool chip + assistant answer")
    func endToEndThroughRunner() async throws {
        let search = MockSearchService()
        let repo = MockDocumentRepository()
        await search.setQueryResults([
            "swift concurrency": [
                SearchResult(
                    documentID: DocumentID(),
                    title: "Swift Concurrency",
                    excerpt: "Actors isolate mutable state.",
                    score: 0.9
                )
            ]
        ])
        let tools: [any AgentTool] = [
            VaultSearchTool(searchService: search),
            ReadDocumentTool(repository: repo),
            CreateNoteTool(repository: repo),
            ListDocumentsTool(repository: repo),
        ]

        // One narrated tool round, then a text-only answer round (ends the loop).
        let model = ScriptedLanguageModel(script: [
            .emitText("I'll search the vault."),
            .callTool(name: "vault_search", arguments: ["query": .string("swift concurrency")]),
            .endTurn,
            .emitText("Actors isolate mutable state — that's the core."),
        ])
        let runner = SessionAgentRunner(model: model, instructions: "system", tools: tools)

        var messages: [ChatMessage] = []
        var state = ChatTurnReducer.State()
        for try await event in await runner.run(prompt: "Explain Swift concurrency") {
            ChatTurnReducer.apply(event, to: &messages, state: &state, context: nil, providerID: .anthropic)
        }

        // A completed vault_search tool chip must appear.
        #expect(messages.contains { $0.role == .tool && $0.toolCall?.name == "vault_search" && $0.toolCall?.isInFlight == false })

        // The tool fires in round 0 BEFORE that round's narration text, so the
        // narration opens a fresh bubble and round 1's answer accumulates into
        // it — the runner emits no bubble-breaking event between them. This
        // single concatenated assistant bubble is exactly the pre-refactor
        // behavior the reducer preserves.
        let assistantText = messages.filter { $0.role == .assistant }.map(\.content)
        #expect(assistantText.contains {
            $0.contains("I'll search the vault.")
            && $0.contains("Actors isolate mutable state — that's the core.")
        })
        // The runner estimates per-round usage, so a final usage is captured.
        #expect(state.lastUsage != nil)
        // Assistant rows carry the provider attribution the panel would set.
        #expect(messages.first { $0.role == .assistant }?.providerID == .anthropic)
    }
}
