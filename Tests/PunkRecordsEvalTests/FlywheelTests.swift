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
}
