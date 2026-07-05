import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals

/// Unit tests for the flywheel driver's pure helpers: deterministic scenario
/// sampling (`ScenarioSampler`) and run-summary formatting (`EvalReportPrinter`).
/// These never hit the network, so they run in the default (non-live) bundle.
@Suite("Flywheel Driver")
struct FlywheelDriverTests {

    // MARK: - Fixtures

    private func makeScenarios(_ count: Int) -> [EvalScenario] {
        (0..<count).map { i in
            EvalScenario(
                id: "scn-\(i)",
                name: "Scenario \(i)",
                description: "",
                category: .simpleQA,
                vaultDocuments: [],
                userPrompt: "Q\(i)",
                groundTruth: GroundTruth(turnRange: 1...1)
            )
        }
    }

    private func makeReport(
        variantID: String,
        scenarios: [(id: String, success: Bool, tokens: Int, turns: Int, tools: Int)],
        timestampOffset: TimeInterval = 0
    ) -> EvalReport {
        let results = scenarios.map { scenario -> ScenarioResult in
            let turns = (0..<scenario.turns).map { i in
                TurnMetrics(
                    turnIndex: i,
                    tokens: TokenMetrics(promptTokens: scenario.tokens / max(scenario.turns, 1), completionTokens: 0),
                    latencyMS: 10,
                    toolCalls: i == 0
                        ? (0..<scenario.tools).map { _ in ToolCallRecord(toolName: "vault_search", latencyMS: 1, isError: false) }
                        : []
                )
            }
            let metrics = TaskMetrics(scenarioID: scenario.id, turns: turns, success: scenario.success)
            return ScenarioResult(
                scenarioID: scenario.id,
                scenarioName: scenario.id,
                success: scenario.success,
                metrics: metrics,
                failureReasons: scenario.success ? [] : ["missing required content: 'foo'"],
                finalOutput: "output"
            )
        }
        return EvalReport(promptVariantID: variantID, results: results)
    }

    // MARK: - ScenarioSampler determinism

    @Test("Sampling is deterministic for the same day")
    func samplingDeterministicSameDay() {
        let scenarios = makeScenarios(21)
        let date = Date(timeIntervalSince1970: 1_751_587_200)  // 2025-07-04
        let a = ScenarioSampler.sample(scenarios, count: 5, date: date).map(\.id)
        let b = ScenarioSampler.sample(scenarios, count: 5, date: date).map(\.id)
        #expect(a == b)
        #expect(a.count == 5)
    }

    @Test("Sample size matches requested count")
    func samplingRespectsCount() {
        let scenarios = makeScenarios(21)
        let date = Date(timeIntervalSince1970: 1_751_587_200)
        for n in [1, 3, 7, 20] {
            #expect(ScenarioSampler.sample(scenarios, count: n, date: date).count == n)
        }
    }

    @Test("Sampling preserves original scenario order")
    func samplingPreservesOrder() {
        let scenarios = makeScenarios(21)
        let date = Date(timeIntervalSince1970: 1_751_587_200)
        let picked = ScenarioSampler.sample(scenarios, count: 6, date: date)
        let indices = picked.map { scn in scenarios.firstIndex { $0.id == scn.id }! }
        #expect(indices == indices.sorted(), "Sampled subset should keep the fixtures' original order")
    }

    @Test("count >= total or <= 0 returns the full set unchanged")
    func samplingNoOpBounds() {
        let scenarios = makeScenarios(5)
        let date = Date()
        #expect(ScenarioSampler.sample(scenarios, count: 5, date: date).map(\.id) == scenarios.map(\.id))
        #expect(ScenarioSampler.sample(scenarios, count: 99, date: date).map(\.id) == scenarios.map(\.id))
        #expect(ScenarioSampler.sample(scenarios, count: 0, date: date).map(\.id) == scenarios.map(\.id))
    }

    @Test("Selection rotates across calendar days (day salt is load-bearing)")
    func samplingRotatesByDay() {
        let scenarios = makeScenarios(21)
        // 30 consecutive days: if the day salt were ignored, every day's 5-pick
        // would be identical. It fails ONLY if the salt is broken — not flaky.
        var seen = Set<[String]>()
        let day: TimeInterval = 86_400
        for i in 0..<30 {
            let date = Date(timeIntervalSince1970: 1_751_587_200 + Double(i) * day)
            seen.insert(ScenarioSampler.sample(scenarios, count: 5, date: date).map(\.id))
        }
        #expect(seen.count > 1, "Sample must vary across days — the date salt is not being applied")
    }

    @Test("Stable hash does not use the per-process seed")
    func stableHashIsProcessStable() {
        // Two calls in-process must agree (true of SipHash too) AND distinct inputs
        // must differ — the real guarantee (reproducibility across processes) is
        // exercised by the same-day determinism test above.
        #expect(ScenarioSampler.stableHash("abc") == ScenarioSampler.stableHash("abc"))
        #expect(ScenarioSampler.stableHash("abc") != ScenarioSampler.stableHash("abd"))
        // FNV-1a offset basis XOR/multiply of a single byte is a fixed value.
        #expect(ScenarioSampler.stableHash("") == 14_695_981_039_346_656_037)
    }

    // MARK: - EvalReportPrinter formatting

    @Test("Report summary renders per-scenario status, pass-rate, mean tools, tokens")
    func printerRendersCoreSections() {
        // Token totals divide evenly by turns so totalTokens is exact (no integer-division loss).
        let report = makeReport(variantID: "terse-v2", scenarios: [
            ("scn-a", true, 1000, 2, 1),
            ("scn-b", false, 2000, 2, 3),
        ])
        let text = EvalReportPrinter.summary(report: report, variantName: "Terse")

        #expect(text.contains("Flywheel Run: terse-v2 (Terse)"))
        #expect(text.contains("[PASS] scn-a"))
        #expect(text.contains("[FAIL] scn-b"))
        #expect(text.contains("missing required content: 'foo'"))  // failure reason surfaced
        #expect(text.contains("Pass rate: 1/2 (50.00%)"))
        #expect(text.contains("Mean tool calls: 2.00"))            // (1 + 3) / 2
        #expect(text.contains("Total tokens (est): 3000"))
        // No previous report ⇒ no trend section.
        #expect(!text.contains("Trend vs previous"))
    }

    @Test("Report summary renders an improving trend delta versus the previous report")
    func printerRendersTrendDelta() {
        let previous = makeReport(variantID: "terse-v2", scenarios: [
            ("scn-a", true, 2000, 2, 2),
            ("scn-b", false, 2000, 2, 2),   // 1/2 pass, 2000 mean tokens
        ])
        let current = makeReport(variantID: "terse-v2", scenarios: [
            ("scn-a", true, 1000, 2, 1),
            ("scn-b", true, 1000, 2, 1),    // 2/2 pass, 1000 mean tokens
        ])
        let text = EvalReportPrinter.summary(report: current, previous: previous, variantName: "Terse")

        #expect(text.contains("Trend vs previous"))
        // Pass rate 0.50 → 1.00 is better (higher is better) ⇒ up arrow.
        #expect(text.contains("Pass rate: 0.50 → 1.00 ↑"))
        // Mean tokens 2000 → 1000 is better (lower is better) ⇒ up-good, down value.
        #expect(text.contains("Mean tokens/task: 2000.00 → 1000.00 ↑"))
    }
}
