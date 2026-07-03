import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals
import PunkRecordsInfra

/// Evaluates turn/tool efficiency and metric aggregation on the **session path**
/// (`ScriptedLanguageModel` → `SessionAgentRunner`).
///
/// Token counts are ESTIMATES: AnyLanguageModel exposes no usage surface, so
/// `SessionAgentRunner` reports `TokenEstimator` heuristics (~4 chars/token)
/// for each round's prompt and completion via `turnEnd`. Assertions here are
/// deliberately loose bounds over those estimates.
@Suite("Token Efficiency Evals")
struct TokenEfficiencyEvals {

    let harness = EvalHarness()

    @Test("Single-turn task stays a single round")
    func singleTurnEfficiency() async throws {
        let scenario = EvalScenario(
            id: "token-single-turn",
            name: "Single Turn Token Check",
            description: "Verify single-turn responses don't spend extra rounds",
            category: .simpleQA,
            vaultDocuments: EvalVaultFixtures.standardVault,
            userPrompt: "What is an actor?",
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            scope: .document(EvalVaultFixtures.concurrencyDocID),
            groundTruth: GroundTruth(turnRange: 1...1)
        )

        let script: [ScriptedLanguageModel.Step] = [
            .emitText("An actor provides data-race safety by isolating mutable state."),
        ]

        let result = try await harness.runMockSession(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")
        #expect(result.metrics.turnCount == 1)
        #expect(result.metrics.toolCallCount == 0)
        // Estimated usage: the round prompt (instructions + request) dominates;
        // the one-sentence completion is small.
        let tokens = result.metrics.totalTokens
        #expect(tokens.promptTokens > 0, "Round prompt should carry estimated tokens")
        #expect(tokens.completionTokens > 0, "Completion should carry estimated tokens")
        #expect(tokens.completionTokens < 100, "One-sentence answer should estimate small")
    }

    @Test("Multi-turn task round growth is bounded")
    func multiTurnTokenGrowth() async throws {
        let scenario = EvalScenario(
            id: "token-multi-turn",
            name: "Multi Turn Token Growth",
            description: "Verify rounds stay bounded across a tool-using task",
            category: .vaultSearchSynthesize,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: ["concurrency": EvalVaultFixtures.concurrencySearchResults],
            userPrompt: "Search and summarize concurrency notes",
            groundTruth: GroundTruth(turnRange: 2...3, minToolCalls: 1)
        )

        let script: [ScriptedLanguageModel.Step] = [
            .callTool(name: "vault_search", arguments: ["query": .string("concurrency")]),
            .endTurn,
            .emitText("Summary of concurrency notes: actors, async/await, task groups."),
        ]

        let result = try await harness.runMockSession(scenario: scenario, script: script)
        #expect(result.success, "Failures: \(result.failureReasons)")

        // One tool-only round, then the answering round.
        let turns = result.metrics.turns
        #expect(turns.count == 2)
        #expect(turns[0].toolCalls.count == 1)
        #expect(turns[1].toolCalls.isEmpty)

        // The second round's prompt folds in the first round's tool results,
        // so its estimated prompt tokens must grow; the tool-only round has no
        // completion tokens.
        #expect(turns[0].tokens.completionTokens == 0)
        #expect(turns[1].tokens.promptTokens > turns[0].tokens.promptTokens,
                "Round 2 prompt should grow by the folded tool results")
        #expect(turns[1].tokens.completionTokens > 0)
    }

    @Test("Cache metric fields survive the report schema on the session path")
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

        let script: [ScriptedLanguageModel.Step] = [.emitText("Response")]

        let result = try await harness.runMockSession(scenario: scenario, script: script)
        let report = EvalReport(results: [result])

        // The session path reports no cache usage yet (PUNK-4bu), but the report
        // schema must keep the fields so historical reports stay comparable.
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
