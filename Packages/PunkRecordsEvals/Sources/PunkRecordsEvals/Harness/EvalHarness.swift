import Foundation
import PunkRecordsCore
import PunkRecordsTestSupport

/// Runs eval scenarios against the agent loop and produces scored results.
public struct EvalHarness: Sendable {

    public init() {}

    /// Run a scenario with a scripted provider (fast, deterministic, no API cost).
    ///
    /// Note: scripted responses are independent of the prompt template, so passing a
    /// variant only tags the result. Mock runs can't evaluate prompt quality — use
    /// `runLive` with different variants to actually A/B test prompts.
    public func runMock(
        scenario: EvalScenario,
        script: [LLMToolResponse],
        variant: PromptVariant? = nil
    ) async throws -> ScenarioResult {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()

        // Seed vault
        for doc in scenario.vaultDocuments {
            try await mockRepo.save(doc)
        }
        await mockSearch.setQueryResults(scenario.queryResultMap)
        await mockSearch.setBacklinkMap(scenario.backlinkMap)

        let provider = ScriptedProvider(script: script)
        let contextBuilder = ContextBuilder(searchService: mockSearch, repository: mockRepo)
        let tools: [any AgentTool] = [
            VaultSearchTool(searchService: mockSearch),
            ReadDocumentTool(repository: mockRepo),
            CreateNoteTool(repository: mockRepo),
            ListDocumentsTool(repository: mockRepo),
        ]

        let agentLoop = AgentLoop(
            provider: provider,
            contextBuilder: contextBuilder,
            tools: tools,
            vaultName: "Eval Vault"
        )

        // Collect events
        let collector = MetricsCollector()
        let stream = await agentLoop.run(
            prompt: scenario.userPrompt,
            scope: scenario.scope,
            currentDocumentID: scenario.currentDocumentID,
            selectedText: nil,
            systemPromptTemplate: variant?.template
        )

        let (metrics, finalText) = try await collector.collect(from: stream, scenarioID: scenario.id)

        // Evaluate against ground truth
        let failures = evaluate(
            output: finalText,
            metrics: metrics,
            groundTruth: scenario.groundTruth,
            repository: mockRepo
        )

        let success = failures.isEmpty && metrics.success
        return ScenarioResult(
            scenarioID: scenario.id,
            scenarioName: scenario.name,
            success: success,
            metrics: metrics,
            failureReasons: failures,
            finalOutput: finalText
        )
    }

    /// Run a scenario with a live provider (slow, costly, real metrics).
    /// Pass `variant` to override the system prompt template and tag the result.
    public func runLive(
        scenario: EvalScenario,
        provider: any LLMProvider,
        variant: PromptVariant? = nil
    ) async throws -> ScenarioResult {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()

        for doc in scenario.vaultDocuments {
            try await mockRepo.save(doc)
        }
        await mockSearch.setQueryResults(scenario.queryResultMap)
        await mockSearch.setBacklinkMap(scenario.backlinkMap)

        let collector = MetricsCollector()
        let instrumented = await InstrumentedProvider(wrapping: provider, collector: collector)
        let contextBuilder = ContextBuilder(searchService: mockSearch, repository: mockRepo)
        let tools: [any AgentTool] = [
            VaultSearchTool(searchService: mockSearch),
            ReadDocumentTool(repository: mockRepo),
            CreateNoteTool(repository: mockRepo),
            ListDocumentsTool(repository: mockRepo),
        ]

        let agentLoop = AgentLoop(
            provider: instrumented,
            contextBuilder: contextBuilder,
            tools: tools,
            vaultName: "Eval Vault"
        )

        let stream = await agentLoop.run(
            prompt: scenario.userPrompt,
            scope: scenario.scope,
            currentDocumentID: scenario.currentDocumentID,
            selectedText: nil,
            systemPromptTemplate: variant?.template
        )

        let (metrics, finalText) = try await collector.collect(from: stream, scenarioID: scenario.id)

        let failures = evaluate(
            output: finalText,
            metrics: metrics,
            groundTruth: scenario.groundTruth,
            repository: mockRepo
        )

        let success = failures.isEmpty && metrics.success
        return ScenarioResult(
            scenarioID: scenario.id,
            scenarioName: scenario.name,
            success: success,
            metrics: metrics,
            failureReasons: failures,
            finalOutput: finalText
        )
    }

    // MARK: - End-to-end variant comparison

    /// Configuration for a single variant run within a comparison.
    public struct VariantRun: Sendable {
        public let variant: PromptVariant
        public let scenarioScripts: [(scenario: EvalScenario, script: [LLMToolResponse])]

        public init(variant: PromptVariant,
                    scenarioScripts: [(scenario: EvalScenario, script: [LLMToolResponse])]) {
            self.variant = variant
            self.scenarioScripts = scenarioScripts
        }
    }

    /// Run a set of scenarios with two different prompt variants and compare the reports.
    /// Uses scripted mock responses — for live A/B testing, see `compareVariantsLive`.
    ///
    /// Returns the two reports plus a comparison. All three are ready to persist via EvalResultStore.
    public func compareVariantsMock(
        baseline: VariantRun,
        candidate: VariantRun
    ) async throws -> (baselineReport: EvalReport, candidateReport: EvalReport, comparison: VariantComparison) {

        var baselineResults: [ScenarioResult] = []
        for pair in baseline.scenarioScripts {
            let result = try await runMock(scenario: pair.scenario, script: pair.script, variant: baseline.variant)
            baselineResults.append(result)
        }

        var candidateResults: [ScenarioResult] = []
        for pair in candidate.scenarioScripts {
            let result = try await runMock(scenario: pair.scenario, script: pair.script, variant: candidate.variant)
            candidateResults.append(result)
        }

        let baselineReport = EvalReport(promptVariantID: baseline.variant.id, results: baselineResults)
        let candidateReport = EvalReport(promptVariantID: candidate.variant.id, results: candidateResults)
        let comparison = VariantComparator().compare(baseline: baselineReport, candidate: candidateReport)

        return (baselineReport, candidateReport, comparison)
    }

    /// Run scenarios live against a real LLM provider with two prompt variants, return
    /// both reports and their comparison.
    ///
    /// ⚠️ Cost: each scenario runs twice (once per variant). For N scenarios, that's 2·N live API calls.
    public func compareVariantsLive(
        baselineVariant: PromptVariant,
        candidateVariant: PromptVariant,
        scenarios: [EvalScenario],
        provider: any LLMProvider
    ) async throws -> (baselineReport: EvalReport, candidateReport: EvalReport, comparison: VariantComparison) {

        var baselineResults: [ScenarioResult] = []
        for scenario in scenarios {
            let result = try await runLive(scenario: scenario, provider: provider, variant: baselineVariant)
            baselineResults.append(result)
        }

        var candidateResults: [ScenarioResult] = []
        for scenario in scenarios {
            let result = try await runLive(scenario: scenario, provider: provider, variant: candidateVariant)
            candidateResults.append(result)
        }

        let baselineReport = EvalReport(promptVariantID: baselineVariant.id, results: baselineResults)
        let candidateReport = EvalReport(promptVariantID: candidateVariant.id, results: candidateResults)
        let comparison = VariantComparator().compare(baseline: baselineReport, candidate: candidateReport)

        return (baselineReport, candidateReport, comparison)
    }

    // MARK: - Ground Truth Evaluation

    private func evaluate(
        output: String,
        metrics: TaskMetrics,
        groundTruth: GroundTruth,
        repository: MockDocumentRepository
    ) -> [String] {
        var failures: [String] = []
        let lower = output.lowercased()

        // Turn count
        if !groundTruth.turnRange.contains(metrics.turnCount) {
            failures.append("Turn count \(metrics.turnCount) outside expected range \(groundTruth.turnRange)")
        }

        // Minimum tool calls
        if metrics.toolCallCount < groundTruth.minToolCalls {
            failures.append("Tool calls \(metrics.toolCallCount) < expected minimum \(groundTruth.minToolCalls)")
        }

        // Required content
        for keyword in groundTruth.requiredContent {
            if !lower.contains(keyword.lowercased()) {
                failures.append("Missing required content: '\(keyword)'")
            }
        }

        // Forbidden content
        for keyword in groundTruth.forbiddenContent {
            if lower.contains(keyword.lowercased()) {
                failures.append("Contains forbidden content: '\(keyword)'")
            }
        }

        // Tool sequence
        if let expected = groundTruth.expectedToolSequence {
            let actualTools = metrics.turns.flatMap { $0.toolCalls.map(\.toolName) }
            for (i, exp) in expected.enumerated() {
                if i < actualTools.count {
                    if actualTools[i] != exp.toolName {
                        failures.append("Tool call \(i): expected '\(exp.toolName)', got '\(actualTools[i])'")
                    }
                } else {
                    failures.append("Missing expected tool call \(i): '\(exp.toolName)'")
                }
            }
        }

        // Structural checks
        for check in groundTruth.structuralChecks {
            if let failure = evaluateStructural(check, output: output) {
                failures.append(failure)
            }
        }

        return failures
    }

    private func evaluateStructural(_ check: StructuralCheck, output: String) -> String? {
        switch check {
        case .hasFrontmatter:
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("---") { return "Missing frontmatter" }
        case .hasH1:
            let hasH1 = output.components(separatedBy: .newlines).contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") &&
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("##")
            }
            if !hasH1 { return "Missing H1 heading" }
        case .hasWikilinks(let min):
            let count = output.components(separatedBy: "[[").count - 1
            if count < min { return "Wikilinks: \(count) < required \(min)" }
        case .hasTags(let min):
            let tagLine = output.components(separatedBy: .newlines).first { $0.contains("tags:") }
            if tagLine == nil && min > 0 { return "Missing tags line" }
        case .hasSections(let min):
            let count = output.components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }.count
            if count < min { return "Sections: \(count) < required \(min)" }
        case .minWordCount(let min):
            let words = output.split(separator: " ").count
            if words < min { return "Word count: \(words) < required \(min)" }
        case .noMetaCommentary:
            let banned = ["Here is the", "Here's the", "I've converted", "Sure, here", "Certainly!"]
            for phrase in banned {
                if output.contains(phrase) { return "Meta-commentary found: '\(phrase)'" }
            }
        }
        return nil
    }
}
