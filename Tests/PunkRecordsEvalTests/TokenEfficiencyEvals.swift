import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals

/// Evaluates token efficiency: budget utilization, cost per task, and metric aggregation.
@Suite("Token Efficiency Evals")
struct TokenEfficiencyEvals {

    let harness = EvalHarness()

    @Test("Single-turn task uses minimal tokens")
    func singleTurnEfficiency() async throws {
        let scenario = EvalScenario(
            id: "token-single-turn",
            name: "Single Turn Token Check",
            description: "Verify single-turn responses don't waste tokens",
            category: .simpleQA,
            vaultDocuments: EvalVaultFixtures.standardVault,
            userPrompt: "What is an actor?",
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            scope: .document(EvalVaultFixtures.concurrencyDocID),
            groundTruth: GroundTruth(turnRange: 1...1)
        )

        let script = [LLMToolResponse(
            contentBlocks: [.text("An actor provides data-race safety by isolating mutable state.")],
            stopReason: .endTurn,
            usage: TokenUsage(promptTokens: 400, completionTokens: 25)
        )]

        let result = try await harness.runMock(scenario: scenario, script: script)
        #expect(result.metrics.totalTokens.totalTokens < 1000, "Single turn should use < 1000 tokens")
        #expect(result.metrics.turnCount == 1)
    }

    @Test("Multi-turn task token growth is bounded")
    func multiTurnTokenGrowth() async throws {
        let scenario = EvalScenario(
            id: "token-multi-turn",
            name: "Multi Turn Token Growth",
            description: "Verify token usage doesn't explode across turns",
            category: .vaultSearchSynthesize,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: ["concurrency": EvalVaultFixtures.concurrencySearchResults],
            userPrompt: "Search and summarize concurrency notes",
            groundTruth: GroundTruth(turnRange: 2...3, minToolCalls: 1)
        )

        let script: [LLMToolResponse] = [
            LLMToolResponse(
                contentBlocks: [
                    .toolUse(id: "t1", name: "vault_search", input: ["query": .string("concurrency")])
                ],
                stopReason: .toolUse,
                usage: TokenUsage(promptTokens: 500, completionTokens: 20)
            ),
            LLMToolResponse(
                contentBlocks: [.text("Summary of concurrency notes: actors, async/await, task groups.")],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 800, completionTokens: 40)
            ),
        ]

        let result = try await harness.runMock(scenario: scenario, script: script)

        // Verify prompt tokens grow but completion stays small
        let turns = result.metrics.turns
        #expect(turns.count == 2)

        // Total tokens should be reasonable for a 2-turn interaction
        #expect(result.metrics.totalTokens.totalTokens < 5000,
                "2-turn task should use < 5000 total tokens, got \(result.metrics.totalTokens.totalTokens)")
    }

    @Test("Cache metrics are tracked in token usage")
    func cacheMetricsTracking() async throws {
        let scenario = EvalScenario(
            id: "cache-tracking",
            name: "Cache Metrics",
            description: "Verify cache fields are captured in metrics",
            category: .simpleQA,
            vaultDocuments: [],
            userPrompt: "Test",
            groundTruth: GroundTruth(turnRange: 1...1)
        )

        let script = [LLMToolResponse(
            contentBlocks: [.text("Response")],
            stopReason: .endTurn,
            usage: TokenUsage(
                promptTokens: 1000,
                completionTokens: 50,
                cacheCreationInputTokens: 800,
                cacheReadInputTokens: 200
            )
        )]

        let result = try await harness.runMock(scenario: scenario, script: script)
        let report = EvalReport(results: [result])

        // Verify JSON round-trip preserves cache metric fields in the schema
        let json = try report.toJSON()
        let jsonString = String(data: json, encoding: .utf8) ?? ""
        #expect(jsonString.contains("cacheCreationInputTokens"), "Report JSON should include cache creation field")
        #expect(jsonString.contains("cacheReadInputTokens"), "Report JSON should include cache read field")

        // Verify round-trip decode
        let decoded = try EvalReport.fromJSON(json)
        #expect(decoded.scenarioResults.count == 1)
    }

    @Test("Aggregate metrics compute correctly")
    func aggregateMetrics() async throws {
        let result1 = ScenarioResult(
            scenarioID: "s1", scenarioName: "S1", success: true,
            metrics: TaskMetrics(scenarioID: "s1", turns: [
                TurnMetrics(turnIndex: 0, tokens: TokenMetrics(promptTokens: 500, completionTokens: 50), latencyMS: 100, toolCalls: [])
            ], success: true),
            failureReasons: [], finalOutput: "Output 1"
        )
        let result2 = ScenarioResult(
            scenarioID: "s2", scenarioName: "S2", success: false,
            metrics: TaskMetrics(scenarioID: "s2", turns: [
                TurnMetrics(turnIndex: 0, tokens: TokenMetrics(promptTokens: 800, completionTokens: 80), latencyMS: 200, toolCalls: [
                    ToolCallRecord(toolName: "vault_search", latencyMS: 5, isError: false)
                ]),
                TurnMetrics(turnIndex: 1, tokens: TokenMetrics(promptTokens: 1000, completionTokens: 100), latencyMS: 300, toolCalls: [])
            ], success: false),
            failureReasons: ["Missing keyword"], finalOutput: "Output 2"
        )

        let report = EvalReport(results: [result1, result2])

        #expect(report.aggregate.totalScenarios == 2)
        #expect(report.aggregate.passedScenarios == 1)
        #expect(report.aggregate.taskCompletionRate == 0.5)
        #expect(report.aggregate.averageTurnsPerTask == 1.5) // (1 + 2) / 2
    }
}
