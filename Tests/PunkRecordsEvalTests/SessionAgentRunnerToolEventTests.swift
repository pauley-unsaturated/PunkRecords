import Testing
import Foundation
import AnyLanguageModel
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport
import PunkRecordsEvals

/// Deterministic, no-network tests for the tool-event plumbing on the **session
/// path** (`SessionAgentRunner` driving a `LanguageModelSession`). This is the
/// session-path analogue of `AgentLoopWebSearchTests`, which exercised the same
/// `toolStart` / `toolEnd` ordering and JSON-argument contract on the legacy
/// `AgentLoop` via `ScriptedProvider`.
///
/// ## Scope difference vs. the AgentLoop version
/// `AgentLoopWebSearchTests` also asserts Anthropic's **native `web_search`
/// server tool** plumbing (`serverTools == [.webSearch(maxUses: 5)]`,
/// `serverToolUse` / `serverToolResult` content blocks → `web_search`
/// `toolStart` / `toolEnd`). That is AgentLoop-specific: AnyLanguageModel's
/// backends (including its remote `AnthropicLanguageModel`) expose **no** native
/// web_search server tool (recon §4), so there is no session-path analogue to
/// port. Those server-tool assertions deliberately remain on the AgentLoop path
/// (`AgentLoopWebSearchTests`), which is kept compiling for exactly this reason.
///
/// What *does* port cleanly is the client-tool event contract: when the model
/// calls a vault tool, `SessionAgentRunner` must emit `toolStart` then `toolEnd`
/// in document order, with the toolStart payload carrying JSON-encoded
/// arguments, and the `toolEnd` `isError` flag round-tripping a failed tool.
@Suite("SessionAgentRunner tool-event plumbing")
struct SessionAgentRunnerToolEventTests {

    /// Build a mock vault with one search hit and the standard tool set, so the
    /// scripted model can call `vault_search` against real Core tools.
    private func makeTools() async -> (search: MockSearchService, repo: MockDocumentRepository, tools: [any AgentTool]) {
        let search = MockSearchService()
        let repo = MockDocumentRepository()
        await search.setQueryResults([
            "swift concurrency": [
                SearchResult(
                    documentID: DocumentID(),
                    title: "Swift Concurrency",
                    excerpt: "Actors isolate mutable state across concurrency domains.",
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
        return (search, repo, tools)
    }

    @Test("Tool-call steps emit toolStart/toolEnd events in document order")
    func toolEventsInOrder() async throws {
        let (_, _, tools) = await makeTools()

        // One round mixing narration and a tool call. The runner drives one
        // `respond` per round: the session resolves the tool call (firing
        // toolStart/toolEnd mid-round) and the round's text arrives as a single
        // textToken AFTER respond returns — so tools precede text, and real turn
        // boundaries bracket the round.
        let model = ScriptedLanguageModel(script: [
            .emitText("I'll search the vault for that.\n"),
            .callTool(name: "vault_search", arguments: ["query": .string("swift concurrency")]),
            .emitText("\nBased on the results, Swift's actor model…"),
        ])

        let runner = SessionAgentRunner(model: model, instructions: "system", tools: tools)

        var events: [AgentEvent] = []
        for try await event in await runner.run(prompt: "What's new in Swift concurrency?") {
            events.append(event)
        }

        let shape: [String] = events.compactMap {
            switch $0 {
            case .agentStart: return nil
            case .textToken: return "text"
            case .toolStart(let name, _): return "start(\(name))"
            case .toolEnd(let name, let result): return "end(\(name),err=\(result.isError))"
            case .turnStart(let index): return "turnStart(\(index))"
            case .turnEnd(let index): return "turnEnd(\(index))"
            case .done: return "done"
            default: return nil
            }
        }

        // Collapse consecutive cumulative-delta "text" entries (the runner may
        // split a chunk across snapshots) so we assert the ordering, not count.
        var collapsed: [String] = []
        for entry in shape where collapsed.last != entry || entry != "text" {
            collapsed.append(entry)
        }

        #expect(collapsed == [
            "turnStart(0)",
            "start(vault_search)",
            "end(vault_search,err=false)",
            "text",
            "turnEnd(0)",
            "done",
        ])

        // The toolStart payload should be JSON-encoded args, not String(describing:).
        let startArgs = events.compactMap { event -> String? in
            if case let .toolStart(_, args) = event { return args }
            return nil
        }.first
        #expect(startArgs?.contains("\"query\"") == true)
        #expect(startArgs?.contains("swift concurrency") == true)
    }

    @Test("A failing tool round-trips isError=true through toolEnd")
    func toolErrorRoundTrips() async throws {
        let (_, _, tools) = await makeTools()

        // read_document with a path that doesn't exist → the Core tool returns an
        // errored ToolResult, which the adapter surfaces as "Error: …", and the
        // runner flags toolEnd.isError == true.
        let model = ScriptedLanguageModel(script: [
            .callTool(name: "read_document", arguments: ["path": .string("Missing/Nope.md")]),
        ])

        let runner = SessionAgentRunner(model: model, instructions: "system", tools: tools)

        var sawError = false
        for try await event in await runner.run(prompt: "read it") {
            if case let .toolEnd(_, result) = event, result.isError {
                sawError = true
            }
        }

        #expect(sawError)
    }

    @Test("A text-only script streams assistant text and finishes with done")
    func textOnlyStreams() async throws {
        let (_, _, tools) = await makeTools()

        let model = ScriptedLanguageModel(script: [
            .emitText("Hello"),
            .emitText(", world"),
        ])
        let runner = SessionAgentRunner(model: model, instructions: "system", tools: tools)

        var finalText = ""
        var sawDone = false
        for try await event in await runner.run(prompt: "hi") {
            switch event {
            case .textToken(let token): finalText += token
            case .done(let text):
                sawDone = true
                #expect(text == "Hello, world")
            default: break
            }
        }

        #expect(sawDone)
        #expect(finalText == "Hello, world")
    }
}
