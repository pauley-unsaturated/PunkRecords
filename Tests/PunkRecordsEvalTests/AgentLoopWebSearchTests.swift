import Testing
import Foundation
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport
import PunkRecordsEvals

/// Deterministic tests for the web_search server-tool plumbing in AgentLoop.
/// Uses ScriptedProvider so we don't hit the real Anthropic API.
@Suite("AgentLoop web_search server-tool plumbing")
struct AgentLoopWebSearchTests {

    private func makeContextBuilder() throws -> (ContextBuilder, @Sendable () -> Void) {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        return (ContextBuilder(searchService: index, repository: repo), cleanup)
    }

    @Test("enableWebSearch=true populates the LLMRequest with .webSearch server tool")
    func enableFlagPlumbsServerTools() async throws {
        let (contextBuilder, cleanup) = try makeContextBuilder()
        defer { cleanup() }

        let response = LLMToolResponse(
            contentBlocks: [.text("ok")],
            stopReason: .endTurn,
            usage: nil
        )
        let provider = ScriptedProvider(script: [response])

        let agent = AgentLoop(
            provider: provider,
            contextBuilder: contextBuilder,
            tools: [],
            vaultName: "Test"
        )

        let stream = await agent.run(
            prompt: "anything",
            scope: .global,
            currentDocumentID: nil,
            selectedText: nil,
            enableWebSearch: true
        )
        for try await _ in stream {}

        let firstRequest = await provider.requestLog.first
        #expect(firstRequest?.serverTools == [.webSearch(maxUses: 5)])
    }

    @Test("enableWebSearch=false leaves serverTools nil")
    func disabledFlagLeavesServerToolsNil() async throws {
        let (contextBuilder, cleanup) = try makeContextBuilder()
        defer { cleanup() }

        let response = LLMToolResponse(
            contentBlocks: [.text("ok")],
            stopReason: .endTurn,
            usage: nil
        )
        let provider = ScriptedProvider(script: [response])

        let agent = AgentLoop(
            provider: provider,
            contextBuilder: contextBuilder,
            tools: [],
            vaultName: "Test"
        )

        let stream = await agent.run(
            prompt: "anything",
            scope: .global,
            currentDocumentID: nil,
            selectedText: nil,
            enableWebSearch: false
        )
        for try await _ in stream {}

        let firstRequest = await provider.requestLog.first
        #expect(firstRequest?.serverTools == nil)
    }

    @Test("Server-tool blocks emit toolStart/toolEnd events in document order")
    func serverToolEventsInOrder() async throws {
        let (contextBuilder, cleanup) = try makeContextBuilder()
        defer { cleanup() }

        let response = LLMToolResponse(
            contentBlocks: [
                .text("I'll search the web for that.\n"),
                .serverToolUse(
                    id: "srvtoolu_1",
                    name: "web_search",
                    input: ["query": .string("swift concurrency")]
                ),
                .serverToolResult(
                    toolUseID: "srvtoolu_1",
                    content: "• Swift Concurrency — swift.org\n  https://swift.org/concurrency",
                    isError: false
                ),
                .text("\nBased on the results, Swift's actor model…"),
            ],
            stopReason: .endTurn,
            usage: nil
        )
        let provider = ScriptedProvider(script: [response])

        let agent = AgentLoop(
            provider: provider,
            contextBuilder: contextBuilder,
            tools: [],
            vaultName: "Test"
        )

        var events: [AgentEvent] = []
        let stream = await agent.run(
            prompt: "What's new in Swift concurrency?",
            scope: .global,
            currentDocumentID: nil,
            selectedText: nil,
            enableWebSearch: true
        )
        for try await event in stream { events.append(event) }

        // Filter to the events we care about, preserving order.
        let shape: [String] = events.compactMap {
            switch $0 {
            case .textToken: return "text"
            case .toolStart(let name, _): return "start(\(name))"
            case .toolEnd(let name, let result): return "end(\(name),err=\(result.isError))"
            case .done: return "done"
            default: return nil
            }
        }

        #expect(shape == [
            "text",
            "start(web_search)",
            "end(web_search,err=false)",
            "text",
            "done"
        ])

        // The toolStart payload should be JSON-encoded args, not Swift's String(describing:).
        let startArgs = events.compactMap { event -> String? in
            if case let .toolStart(_, args) = event { return args }
            return nil
        }.first
        #expect(startArgs?.contains("\"query\"") == true)
        #expect(startArgs?.contains("swift concurrency") == true)
    }

    @Test("web_search_tool_result with isError=true round-trips through toolEnd")
    func serverToolErrorRoundTrips() async throws {
        let (contextBuilder, cleanup) = try makeContextBuilder()
        defer { cleanup() }

        let response = LLMToolResponse(
            contentBlocks: [
                .serverToolUse(
                    id: "srvtoolu_e",
                    name: "web_search",
                    input: ["query": .string("anything")]
                ),
                .serverToolResult(
                    toolUseID: "srvtoolu_e",
                    content: "Web search error: max_uses_exceeded",
                    isError: true
                ),
            ],
            stopReason: .endTurn,
            usage: nil
        )
        let provider = ScriptedProvider(script: [response])

        let agent = AgentLoop(
            provider: provider,
            contextBuilder: contextBuilder,
            tools: [],
            vaultName: "Test"
        )

        var sawError = false
        let stream = await agent.run(
            prompt: "anything",
            scope: .global,
            currentDocumentID: nil,
            selectedText: nil,
            enableWebSearch: true
        )
        for try await event in stream {
            if case let .toolEnd(_, result) = event, result.isError {
                sawError = true
            }
        }

        #expect(sawError)
    }
}
