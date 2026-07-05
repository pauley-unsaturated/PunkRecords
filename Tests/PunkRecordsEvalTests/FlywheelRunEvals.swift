import Testing
import Foundation
import AnyLanguageModel
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport
import PunkRecordsEvals

/// The flywheel **driver**: runs the orphaned `EvalVaultFixtures.diverseScenarios`
/// set through `EvalHarness.runLiveSession` with the current `PromptVariant`,
/// aggregates an `EvalReport`, persists it via `EvalResultStore`, and prints a
/// human-readable summary plus a trend delta versus the previous stored report.
///
/// Opt-in only: set `PUNKRECORDS_LIVE_EVALS=1` to run (real Anthropic API calls,
/// real money — mirror `LiveSessionAgentEvals`). Under `xcodebuild` the env var
/// arrives as `TEST_RUNNER_PUNKRECORDS_LIVE_EVALS`, which the test runner strips
/// back to `PUNKRECORDS_LIVE_EVALS` before `ProcessInfo` sees it. `.serialized`
/// to avoid hammering the provider.
///
/// Knobs (all read from the environment):
/// - `PUNKRECORDS_EVAL_SAMPLE=n` — run a deterministic `n`-scenario subset (same
///   `n` on the same calendar day picks the same scenarios; see `ScenarioSampler`).
/// - `PUNKRECORDS_EVAL_VARIANT_B=<variant-id>` — also run an A/B comparison of the
///   current variant (baseline) against the stored variant `<variant-id>`
///   (candidate) via `compareVariantsLiveSession`, printing the recommendation.
@Suite(
    "Flywheel Run Evals",
    .tags(.eval),
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PUNKRECORDS_LIVE_EVALS"] == "1")
)
struct FlywheelRunEvals {

    static let keychain = KeychainService()

    static func requireAPIKey() throws {
        guard let key = try? keychain.apiKey(for: "anthropic"), key != nil else {
            throw FlywheelSkipError("No Anthropic API key in keychain — skipping flywheel run")
        }
    }

    static func anthropicModel() throws -> any LanguageModel {
        try LanguageModelFactory.makeModel(for: .anthropic, keychain: keychain)
    }

    /// Resolve the scenario set for this invocation, honoring `PUNKRECORDS_EVAL_SAMPLE`.
    static func resolvedScenarios(env: [String: String]) -> [EvalScenario] {
        let all = EvalVaultFixtures.diverseScenarios
        if let raw = env["PUNKRECORDS_EVAL_SAMPLE"], let n = Int(raw), n > 0 {
            return ScenarioSampler.sample(all, count: n)
        }
        return all
    }

    @Test("Flywheel: run current variant over diverse scenarios, persist + trend")
    func runFlywheel() async throws {
        try Self.requireAPIKey()

        let env = ProcessInfo.processInfo.environment
        let variant = PromptVariant.current
        let scenarios = Self.resolvedScenarios(env: env)

        let harness = EvalHarness()
        let model = try Self.anthropicModel()

        var results: [ScenarioResult] = []
        for scenario in scenarios {
            let result = try await harness.runLiveSession(scenario: scenario, model: model, variant: variant)
            results.append(result)
            print("[FLYWHEEL] \(result.success ? "PASS" : "FAIL") \(result.scenarioID)"
                + " (tools=\(result.metrics.toolCallCount), tokens=\(result.metrics.totalTokens.totalTokens))")
        }

        let report = EvalReport(promptVariantID: variant.id, results: results)

        // Persist to ~/.punkrecords/eval-results. Record the active variant too
        // (idempotent) so the store is self-describing for future A/B runs.
        let store = EvalResultStore()
        try? store.save(variant)
        // Snapshot the previous report BEFORE saving the new one, so the trend
        // delta compares against genuine history rather than this very run.
        let previous = try? store.latestForVariant(variant.id)
        try store.save(report)

        print("")
        print(EvalReportPrinter.summary(report: report, previous: previous, variantName: variant.name))

        // A/B path — only when a candidate variant is named and resolvable.
        if let candidateID = env["PUNKRECORDS_EVAL_VARIANT_B"], !candidateID.isEmpty {
            if let candidate = try store.loadVariant(candidateID) {
                print("")
                print("[FLYWHEEL] A/B: \(variant.id) (baseline) vs \(candidate.id) (candidate) — \(scenarios.count) scenarios ×2")
                let (baselineReport, candidateReport, comparison) = try await harness.compareVariantsLiveSession(
                    baselineVariant: variant,
                    candidateVariant: candidate,
                    scenarios: scenarios,
                    model: model
                )
                try store.save(baselineReport)
                try store.save(candidateReport)
                print(comparison.summary)
                print("[FLYWHEEL] Recommendation: \(comparison.overallRecommendation.rawValue)")
            } else {
                print("[FLYWHEEL] Variant B '\(candidateID)' not found in store "
                    + "(\(store.directory.appendingPathComponent("variants").path)); skipping A/B.")
            }
        }

        #expect(!report.scenarioResults.isEmpty, "Flywheel run produced no scenario results")
    }
}

private struct FlywheelSkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
