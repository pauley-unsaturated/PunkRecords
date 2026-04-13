import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals

/// Tests for the flywheel infrastructure: variant storage, report persistence, A/B comparison.
@Suite("Flywheel")
struct FlywheelTests {

    // MARK: - Helpers

    func makeReport(
        variantID: String,
        scenarios: [(id: String, success: Bool, tokens: Int, turns: Int)]
    ) -> EvalReport {
        let results = scenarios.map { scenario -> ScenarioResult in
            let turns = (0..<scenario.turns).map { i in
                TurnMetrics(
                    turnIndex: i,
                    tokens: TokenMetrics(promptTokens: scenario.tokens / scenario.turns, completionTokens: 50),
                    latencyMS: 100,
                    toolCalls: []
                )
            }
            let metrics = TaskMetrics(scenarioID: scenario.id, turns: turns, success: scenario.success)
            return ScenarioResult(
                scenarioID: scenario.id,
                scenarioName: scenario.id,
                success: scenario.success,
                metrics: metrics,
                failureReasons: scenario.success ? [] : ["mock failure"],
                finalOutput: "Mock output"
            )
        }
        return EvalReport(promptVariantID: variantID, results: results)
    }

    func makeTempStore() throws -> (EvalResultStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("punkrecords-flywheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (EvalResultStore(directory: tempDir), tempDir)
    }

    // MARK: - PromptVariant

    @Test("Baseline variant has expected metadata")
    func baselineVariant() {
        let baseline = PromptVariant.baseline
        #expect(baseline.id == "baseline-v1")
        #expect(baseline.version == 1)
        #expect(baseline.parentVariantID == nil)
        #expect(baseline.template.contains("research assistant"))
        #expect(baseline.template.contains("{vault_name}"))
    }

    @Test("PromptVariant round-trips through JSON")
    func variantJSONRoundTrip() throws {
        let original = PromptVariant(
            id: "test-v2", name: "Test Variant", version: 2,
            description: "Test", template: "Be helpful for {vault_name}",
            parentVariantID: "baseline-v1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PromptVariant.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.version == original.version)
        #expect(decoded.parentVariantID == "baseline-v1")
    }

    // MARK: - EvalResultStore

    @Test("Store saves and loads reports")
    func storeRoundTrip() throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let report = makeReport(variantID: "v1", scenarios: [
            ("scenario-a", true, 1000, 1),
            ("scenario-b", false, 2000, 2),
        ])

        let url = try store.save(report)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].promptVariantID == "v1")
        #expect(loaded[0].scenarioResults.count == 2)
    }

    @Test("Store filters reports by variant ID")
    func loadForVariant() async throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try store.save(makeReport(variantID: "v1", scenarios: [("a", true, 100, 1)]))
        try await Task.sleep(for: .milliseconds(10))  // ensure different timestamps
        try store.save(makeReport(variantID: "v2", scenarios: [("a", true, 120, 1)]))
        try await Task.sleep(for: .milliseconds(10))
        try store.save(makeReport(variantID: "v1", scenarios: [("a", true, 90, 1)]))

        let v1Reports = try store.loadForVariant("v1")
        let v2Reports = try store.loadForVariant("v2")
        #expect(v1Reports.count == 2)
        #expect(v2Reports.count == 1)
    }

    @Test("Store returns latest report for variant")
    func latestForVariant() async throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try store.save(makeReport(variantID: "v1", scenarios: [("a", true, 1000, 1)]))
        try await Task.sleep(for: .milliseconds(10))
        let second = makeReport(variantID: "v1", scenarios: [("a", true, 500, 1)])
        try store.save(second)

        let latest = try store.latestForVariant("v1")
        #expect(latest != nil)
        // second save had 500 prompt tokens + 50 completion = 550 total per the helper
        #expect(latest?.aggregate.totalTokens == 550)
    }

    @Test("Store saves and loads prompt variants")
    func variantStorage() throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try store.save(PromptVariant.baseline)
        let loaded = try store.loadVariant("baseline-v1")
        #expect(loaded?.id == "baseline-v1")
        #expect(loaded?.template.contains("research assistant") == true)

        let all = try store.loadAllVariants()
        #expect(all.count == 1)
    }

    @Test("Trend query returns values in chronological order")
    func trendQuery() async throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try store.save(makeReport(variantID: "v1", scenarios: [("a", true, 1000, 1), ("b", false, 2000, 2)]))
        try await Task.sleep(for: .milliseconds(10))
        try store.save(makeReport(variantID: "v2", scenarios: [("a", true, 800, 1), ("b", true, 1500, 2)]))

        let completionTrend = try store.trend(metric: "taskCompletionRate")
        #expect(completionTrend.count == 2)
        #expect(completionTrend[0].value == 0.5)   // 1/2 passed in v1
        #expect(completionTrend[1].value == 1.0)   // 2/2 passed in v2
        #expect(completionTrend[0].variantID == "v1")
        #expect(completionTrend[1].variantID == "v2")
    }

    // MARK: - VariantComparator

    @Test("Comparator detects clear candidate win")
    func comparatorPromote() {
        let baseline = makeReport(variantID: "v1", scenarios: [
            ("a", true, 2000, 3),
            ("b", true, 3000, 4),
        ])
        let candidate = makeReport(variantID: "v2", scenarios: [
            ("a", true, 1500, 2),   // fewer tokens, fewer turns
            ("b", true, 2500, 3),
        ])

        let comparison = VariantComparator().compare(baseline: baseline, candidate: candidate)
        #expect(comparison.overallRecommendation == .promoteCandidate)
        #expect(comparison.regressedScenarios.isEmpty)
    }

    @Test("Comparator flags regression when candidate breaks a passing scenario")
    func comparatorRegression() {
        let baseline = makeReport(variantID: "v1", scenarios: [
            ("a", true, 1000, 1),
            ("b", true, 1000, 1),
        ])
        let candidate = makeReport(variantID: "v2", scenarios: [
            ("a", true, 900, 1),
            ("b", false, 1200, 1),  // regressed
        ])

        let comparison = VariantComparator().compare(baseline: baseline, candidate: candidate)
        #expect(comparison.regressedScenarios == ["b"])
        #expect(comparison.overallRecommendation == .keepBaseline)
    }

    @Test("Comparator recognizes recovered scenarios")
    func comparatorRecovery() {
        let baseline = makeReport(variantID: "v1", scenarios: [
            ("a", false, 1000, 1),
        ])
        let candidate = makeReport(variantID: "v2", scenarios: [
            ("a", true, 1000, 1),
        ])

        let comparison = VariantComparator().compare(baseline: baseline, candidate: candidate)
        #expect(comparison.recoveredScenarios == ["a"])
    }

    @Test("Comparator rejects candidate that lowers completion rate")
    func comparatorCompletionGate() {
        let baseline = makeReport(variantID: "v1", scenarios: [
            ("a", true, 1000, 1),
            ("b", true, 1000, 1),
        ])
        let candidate = makeReport(variantID: "v2", scenarios: [
            ("a", true, 500, 1),     // cheaper
            ("b", false, 600, 1),    // but broken
        ])

        let comparison = VariantComparator().compare(baseline: baseline, candidate: candidate)
        #expect(comparison.overallRecommendation == .keepBaseline)
    }

    @Test("Comparison summary produces readable markdown")
    func comparisonSummary() {
        let baseline = makeReport(variantID: "v1", scenarios: [("a", true, 1000, 2)])
        let candidate = makeReport(variantID: "v2", scenarios: [("a", true, 800, 1)])
        let comparison = VariantComparator().compare(baseline: baseline, candidate: candidate)
        let summary = comparison.summary
        #expect(summary.contains("v1 → v2"))
        #expect(summary.contains("Recommendation"))
        #expect(summary.contains("Metrics"))
    }

    // MARK: - End-to-end variant comparison

    @Test("End-to-end compareVariantsMock produces matched reports and comparison")
    func endToEndMockComparison() async throws {
        let harness = EvalHarness()

        let baselineVariant = PromptVariant.baseline
        let candidateVariant = PromptVariant(
            id: "terse-v1", name: "Terse", version: 1,
            description: "Shorter responses",
            template: "You are a terse research assistant for {vault_name}. Be brief.",
            parentVariantID: "baseline-v1"
        )

        // One-scenario dataset
        let scenario = EvalScenario(
            id: "e2e-test",
            name: "E2E Test",
            description: "End-to-end smoke",
            category: .simpleQA,
            vaultDocuments: [],
            userPrompt: "Say hi",
            groundTruth: GroundTruth(turnRange: 1...1)
        )
        let script: [LLMToolResponse] = [
            LLMToolResponse(
                contentBlocks: [.text("Hi!")],
                stopReason: .endTurn,
                usage: TokenUsage(promptTokens: 100, completionTokens: 10)
            )
        ]

        let result = try await harness.compareVariantsMock(
            baseline: EvalHarness.VariantRun(variant: baselineVariant,
                                              scenarioScripts: [(scenario, script)]),
            candidate: EvalHarness.VariantRun(variant: candidateVariant,
                                               scenarioScripts: [(scenario, script)])
        )

        #expect(result.baselineReport.promptVariantID == "baseline-v1")
        #expect(result.candidateReport.promptVariantID == "terse-v1")
        #expect(result.baselineReport.scenarioResults.count == 1)
        #expect(result.candidateReport.scenarioResults.count == 1)
        #expect(result.comparison.baselineVariantID == "baseline-v1")
        #expect(result.comparison.candidateVariantID == "terse-v1")
        // Scripted responses are identical → both reports should match
        #expect(result.comparison.regressedScenarios.isEmpty)
    }

    @Test("End-to-end flow persists reports and variants through EvalResultStore")
    func endToEndWithPersistence() async throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let harness = EvalHarness()

        let baseline = PromptVariant.baseline
        let candidate = PromptVariant(
            id: "detail-v1", name: "Detailed", version: 1,
            description: "Longer responses",
            template: "You are a thorough research assistant for {vault_name}.",
            parentVariantID: "baseline-v1"
        )

        try store.save(baseline)
        try store.save(candidate)

        let scenario = EvalScenario(
            id: "persist-test", name: "Persist Test", description: "",
            category: .simpleQA, vaultDocuments: [],
            userPrompt: "Test",
            groundTruth: GroundTruth(turnRange: 1...1)
        )
        let script = [LLMToolResponse(
            contentBlocks: [.text("OK")], stopReason: .endTurn,
            usage: TokenUsage(promptTokens: 50, completionTokens: 5)
        )]

        let result = try await harness.compareVariantsMock(
            baseline: EvalHarness.VariantRun(variant: baseline, scenarioScripts: [(scenario, script)]),
            candidate: EvalHarness.VariantRun(variant: candidate, scenarioScripts: [(scenario, script)])
        )

        try store.save(result.baselineReport)
        try store.save(result.candidateReport)

        // Verify storage round-trips
        let allReports = try store.loadAll()
        #expect(allReports.count == 2)

        let allVariants = try store.loadAllVariants()
        #expect(allVariants.count == 2)

        let baselineReports = try store.loadForVariant("baseline-v1")
        let candidateReports = try store.loadForVariant("detail-v1")
        #expect(baselineReports.count == 1)
        #expect(candidateReports.count == 1)

        // Recompute comparison from loaded data — should match
        let recomputed = VariantComparator().compare(
            baseline: baselineReports[0],
            candidate: candidateReports[0]
        )
        #expect(recomputed.baselineVariantID == "baseline-v1")
        #expect(recomputed.candidateVariantID == "detail-v1")
    }
}
