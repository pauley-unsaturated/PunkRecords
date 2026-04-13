import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals

/// Agent task completion evals — runs scenarios with scripted provider responses
/// to verify the agent loop behaves correctly across different task types.
@Suite("Task Completion Evals")
struct TaskCompletionEvals {

    let harness = EvalHarness()

    // MARK: - Scenario 1: Simple Q&A (no tool use)

    @Test("Simple Q&A: agent responds without tools when context is pre-loaded")
    func simpleQA() async throws {
        let scenario = EvalScenario(
            id: "simple-qa",
            name: "Simple Q&A",
            description: "Agent answers from pre-loaded context without calling tools",
            category: .simpleQA,
            vaultDocuments: EvalVaultFixtures.standardVault,
            userPrompt: "What do my notes say about actor reentrancy?",
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            scope: .document(EvalVaultFixtures.concurrencyDocID),
            groundTruth: GroundTruth(
                turnRange: 1...1,
                requiredContent: ["reentrancy"],
                minToolCalls: 0
            )
        )

        let script: [LLMToolResponse] = [
            LLMToolResponse(
                contentBlocks: [.text("""
                Your notes describe actor reentrancy as a subtle issue in Swift concurrency. \
                When an actor method hits a suspension point (`await`), other callers can execute \
                on the actor in the meantime. The key takeaway from [[Actor Reentrancy]] is to \
                always re-check preconditions after suspension points.
                """)],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 500, completionTokens: 80)
            )
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
        #expect(result.metrics.turnCount == 1)
        #expect(result.metrics.toolCallCount == 0)
    }

    // MARK: - Scenario 2: Vault Search + Synthesize

    @Test("Search + synthesize: agent searches vault and composes answer")
    func searchSynthesize() async throws {
        let scenario = EvalScenario(
            id: "search-synthesize",
            name: "Search + Synthesize",
            description: "Agent searches the vault, reads results, and synthesizes an answer",
            category: .vaultSearchSynthesize,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: ["graph": EvalVaultFixtures.graphSearchResults],
            userPrompt: "Find everything I've written about graph theory and summarize it",
            groundTruth: GroundTruth(
                expectedToolSequence: [
                    ExpectedToolCall(toolName: "vault_search"),
                    ExpectedToolCall(toolName: "read_document"),
                ],
                turnRange: 2...4,
                requiredContent: ["graph", "vertices"],
                minToolCalls: 2
            )
        )

        let script: [LLMToolResponse] = [
            // Turn 1: agent decides to search
            LLMToolResponse(
                contentBlocks: [
                    .text("Let me search your vault for graph theory notes."),
                    .toolUse(id: "tool_1", name: "vault_search", input: ["query": .string("graph theory")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 600, completionTokens: 40)
            ),
            // Turn 2: agent reads the found document
            LLMToolResponse(
                contentBlocks: [
                    .text("I found a note. Let me read it."),
                    .toolUse(id: "tool_2", name: "read_document", input: ["path": .string("math/graph-theory-basics.md")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 800, completionTokens: 30)
            ),
            // Turn 3: agent synthesizes
            LLMToolResponse(
                contentBlocks: [.text("""
                Here's a summary of your graph theory notes:

                Your [[Graph Theory Basics]] note covers the fundamentals: a graph G = (V, E) \
                consists of vertices and edges. You distinguish between directed and undirected \
                graphs, noting that wikilinks in a knowledge base are directed but backlinks \
                make them bidirectional.
                """)],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 1200, completionTokens: 100)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
        #expect(result.metrics.turnCount == 3)
        #expect(result.metrics.toolCallCount == 2)
    }

    // MARK: - Scenario 3: Note Creation

    @Test("Note creation: agent creates a well-structured note")
    func noteCreation() async throws {
        let scenario = EvalScenario(
            id: "note-creation",
            name: "Note Creation",
            description: "Agent searches vault then creates a new note",
            category: .noteCreation,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: ["actor": EvalVaultFixtures.concurrencySearchResults],
            userPrompt: "Create a new note summarizing the relationship between actors and Sendable",
            groundTruth: GroundTruth(
                expectedToolSequence: [
                    ExpectedToolCall(toolName: "vault_search"),
                    ExpectedToolCall(toolName: "create_note"),
                ],
                turnRange: 2...4,
                requiredContent: ["created note"],
                minToolCalls: 2
            )
        )

        let script: [LLMToolResponse] = [
            // Turn 1: search
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "tool_1", name: "vault_search", input: ["query": .string("actors Sendable")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 500, completionTokens: 20)
            ),
            // Turn 2: create note
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "tool_2", name: "create_note", input: [
                        "title": .string("Actors and Sendable"),
                        "content": .string("Actors enforce isolation. Sendable marks types safe to cross boundaries."),
                        "tags": .array([.string("swift"), .string("concurrency")])
                    ])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 900, completionTokens: 50)
            ),
            // Turn 3: confirm
            LLMToolResponse(
                contentBlocks: [.text("I've created note 'Actors and Sendable' summarizing the relationship.")],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 1000, completionTokens: 30)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
        #expect(result.metrics.toolCallCount >= 2)
    }

    // MARK: - Scenario 4: Multi-step Research

    @Test("Multi-step research: agent searches, reads multiple docs, creates note")
    func multiStepResearch() async throws {
        let scenario = EvalScenario(
            id: "multi-step-research",
            name: "Multi-step Research",
            description: "Agent performs multiple searches and reads to research a topic",
            category: .multiStepResearch,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: [
                "reentrancy": [EvalVaultFixtures.concurrencySearchResults[1]],
                "task group": [SearchResult(
                    documentID: EvalVaultFixtures.taskGroupDocID,
                    title: "Task Groups in Practice",
                    excerpt: "Task groups provide structured fan-out.",
                    score: 0.88
                )],
            ],
            userPrompt: "Research how actor reentrancy relates to task groups and write up your findings",
            groundTruth: GroundTruth(
                turnRange: 3...8,
                requiredContent: ["reentrancy", "task group"],
                minToolCalls: 4
            )
        )

        let script: [LLMToolResponse] = [
            // Turn 1: search reentrancy
            LLMToolResponse(
                contentBlocks: [
                    .text("Let me research this topic."),
                    .toolUse(id: "t1", name: "vault_search", input: ["query": .string("actor reentrancy")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 500, completionTokens: 30)
            ),
            // Turn 2: read reentrancy doc + search task groups
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t2", name: "read_document", input: ["path": .string("swift/actor-reentrancy.md")]),
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 700, completionTokens: 20)
            ),
            // Turn 3: search task groups
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t3", name: "vault_search", input: ["query": .string("task group")]),
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 900, completionTokens: 20)
            ),
            // Turn 4: read task group doc
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t4", name: "read_document", input: ["path": .string("swift/task-groups.md")]),
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 1100, completionTokens: 20)
            ),
            // Turn 5: create note
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t5", name: "create_note", input: [
                        "title": .string("Actor Reentrancy and Task Groups"),
                        "content": .string("Both actor reentrancy and task group cancellation require careful state management."),
                        "tags": .array([.string("swift"), .string("concurrency")])
                    ])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 1300, completionTokens: 40)
            ),
            // Turn 6: final response
            LLMToolResponse(
                contentBlocks: [.text("""
                I've researched actor reentrancy and task groups and created a note with my findings. \
                The key connection is that both require careful handling of suspension points — \
                reentrancy can interleave actor state, while task group cancellation must be propagated correctly.
                """)],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 1500, completionTokens: 80)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
        #expect(result.metrics.turnCount >= 3)
        #expect(result.metrics.toolCallCount >= 4)
    }

    // MARK: - Scenario 5: Empty Vault

    @Test("Empty vault: agent handles gracefully")
    func emptyVault() async throws {
        let scenario = EvalScenario(
            id: "empty-vault",
            name: "Empty Vault",
            description: "Agent should handle empty vault without crashing",
            category: .edgeCaseEmpty,
            vaultDocuments: [],
            userPrompt: "What do my notes say about quantum computing?",
            groundTruth: GroundTruth(
                turnRange: 1...3,
                forbiddenContent: ["error", "crash"]
            )
        )

        let script: [LLMToolResponse] = [
            // Agent searches and finds nothing
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t1", name: "vault_search", input: ["query": .string("quantum computing")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 400, completionTokens: 20)
            ),
            // Agent responds gracefully
            LLMToolResponse(
                contentBlocks: [.text("I searched your vault but didn't find any notes about quantum computing. You haven't written about this topic yet.")],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 500, completionTokens: 30)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
    }

    // MARK: - Scenario 6: Contradictory Information

    @Test("Contradictory info: agent notes the contradiction")
    func contradictoryInfo() async throws {
        let scenario = EvalScenario(
            id: "contradiction",
            name: "Contradictory Information",
            description: "Agent should notice contradicting information in vault documents",
            category: .edgeCaseContradiction,
            vaultDocuments: [EvalVaultFixtures.contradictDoc1, EvalVaultFixtures.contradictDoc2],
            queryResultMap: ["actor performance": EvalVaultFixtures.actorPerformanceSearchResults],
            userPrompt: "What's the consensus on actor performance in Swift?",
            groundTruth: GroundTruth(
                turnRange: 1...4,
                requiredContent: ["contradict"]
            )
        )

        let script: [LLMToolResponse] = [
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t1", name: "vault_search", input: ["query": .string("actor performance")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 400, completionTokens: 20)
            ),
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t2", name: "read_document", input: ["path": .string("swift/actor-performance-fast.md")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 600, completionTokens: 15)
            ),
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t3", name: "read_document", input: ["path": .string("swift/actor-overhead-analysis.md")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 800, completionTokens: 15)
            ),
            LLMToolResponse(
                contentBlocks: [.text("""
                Your notes actually contradict each other on actor performance. \
                [[Actor Performance Notes]] claims actors are "extremely fast" with <1ns overhead, \
                while [[Actor Overhead Analysis]] says overhead is ~50ns and can balloon under contention. \
                You may want to reconcile these with actual benchmarks.
                """)],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 1000, completionTokens: 80)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
    }

    // MARK: - Metrics Reporting

    @Test("All scenarios produce a valid EvalReport")
    func evalReportGeneration() async throws {
        // Run a simple scenario and verify report serialization
        let scenario = EvalScenario(
            id: "report-test",
            name: "Report Generation Test",
            description: "Verify eval report serializes correctly",
            category: .simpleQA,
            vaultDocuments: [],
            userPrompt: "Hello",
            groundTruth: GroundTruth(turnRange: 1...1)
        )

        let script = [LLMToolResponse(
            contentBlocks: [.text("Hello!")],
            stopReason: .endTurn,
            usage: TokenUsage(promptTokens: 100, completionTokens: 10)
        )]

        let result = try await harness.runMock(scenario: scenario, script: script)
        let report = EvalReport(results: [result])

        // Verify JSON round-trip
        let json = try report.toJSON()
        let decoded = try EvalReport.fromJSON(json)
        #expect(decoded.scenarioResults.count == 1)
        #expect(decoded.aggregate.totalScenarios == 1)
        #expect(decoded.aggregate.taskCompletionRate > 0)
    }
}
