import Testing
import Foundation
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsEvals

/// Live prompt variant A/B comparisons. Each test runs N scenarios with two different
/// PromptVariants against the real Anthropic API, then produces a VariantComparison.
///
/// Results are persisted to ~/.punkrecords/eval-results/ for trend analysis.
/// Tagged `.eval` so they don't run by default — each test costs real API credits.
@Suite("Live Variant Comparison", .tags(.eval), .serialized)
struct LiveVariantComparison {

    static let keychain = KeychainService()

    static func requireAPIKey() throws {
        guard let key = try? keychain.apiKey(for: "anthropic"), key != nil else {
            throw SkipError("No Anthropic API key in keychain — skipping live variant comparison")
        }
    }

    // MARK: - Prompt Variants Under Test

    /// The current production baseline from ContextBuilder.
    static let baselineVariant = PromptVariant.baseline

    /// Hypothesis: a shorter, more directive prompt will reduce completion tokens
    /// without hurting task completion.
    static let terseVariant = PromptVariant(
        id: "terse-v1",
        name: "Terse",
        version: 1,
        description: """
        Shorter prompt with explicit conciseness directive. Hypothesis: reduces \
        completion tokens by encouraging tighter responses.
        """,
        template: """
        You are a terse research assistant for "{vault_name}". Rules:
        - Answer directly, no preamble.
        - Cite notes as [[Note Title]].
        - One short paragraph unless the user asks for more.
        - Flag contradictions or gaps in one line.
        """,
        parentVariantID: "baseline-v1"
    )

    // MARK: - A/B Comparison

    @Test("Baseline vs Terse — 2 scenarios, live API")
    func baselineVsTerse() async throws {
        try Self.requireAPIKey()

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        let store = EvalResultStore()

        // Persist the variants themselves so they're linked to the reports
        try store.save(Self.baselineVariant)
        try store.save(Self.terseVariant)

        print("[VARIANT] Starting baseline vs terse comparison…")
        print("[VARIANT] Scenarios: \(EvalVaultFixtures.liveScenarios.map(\.id))")

        let result = try await harness.compareVariantsLive(
            baselineVariant: Self.baselineVariant,
            candidateVariant: Self.terseVariant,
            scenarios: EvalVaultFixtures.liveScenarios,
            provider: provider
        )

        // Persist both reports
        let baselineURL = try store.save(result.baselineReport)
        let candidateURL = try store.save(result.candidateReport)

        // Save the comparison summary as markdown for easy review
        let reportsDir = store.directory.appendingPathComponent("reports", isDirectory: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let summaryURL = reportsDir.appendingPathComponent("\(timestamp)-COMPARISON-baseline-vs-terse.md")
        try result.comparison.summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        // Print full comparison
        print("\n" + String(repeating: "=", count: 70))
        print(result.comparison.summary)
        print(String(repeating: "=", count: 70) + "\n")

        // Per-scenario breakdown
        print("[VARIANT] Per-scenario breakdown:")
        for delta in result.comparison.scenarioDeltas {
            print("  - \(delta.scenarioID): " +
                  "passed \(delta.baselinePassed)→\(delta.candidatePassed), " +
                  "tokens \(delta.tokenDelta >= 0 ? "+" : "")\(delta.tokenDelta), " +
                  "turns \(delta.turnDelta >= 0 ? "+" : "")\(delta.turnDelta)")
        }

        // Aggregate totals
        let b = result.baselineReport.aggregate
        let c = result.candidateReport.aggregate
        print("[VARIANT] Aggregate totals:")
        print("  baseline:  \(b.passedScenarios)/\(b.totalScenarios) passed, \(b.totalTokens) tokens")
        print("  candidate: \(c.passedScenarios)/\(c.totalScenarios) passed, \(c.totalTokens) tokens")
        print("[VARIANT] Recommendation: \(result.comparison.overallRecommendation.rawValue)")

        print("[VARIANT] Reports written to:")
        print("  baseline:   \(baselineURL.path)")
        print("  candidate:  \(candidateURL.path)")
        print("  comparison: \(summaryURL.path)")

        // The test always produces data — success isn't tied to which variant won.
        #expect(result.baselineReport.scenarioResults.count == EvalVaultFixtures.liveScenarios.count)
        #expect(result.candidateReport.scenarioResults.count == EvalVaultFixtures.liveScenarios.count)
    }

    // MARK: - Full 20-scenario diverse comparison

    /// Run the full 20-scenario diverse set against both variants.
    /// ⚠️ Cost: ~$0.30–0.60 and ~5–10 minutes of wall time.
    @Test("Baseline vs Terse — 20 diverse scenarios, live API")
    func baselineVsTerseFull() async throws {
        try Self.requireAPIKey()

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        let store = EvalResultStore()

        try store.save(Self.baselineVariant)
        try store.save(Self.terseVariant)

        print("[DIVERSE] Starting 20-scenario baseline vs terse comparison…")
        print("[DIVERSE] This will take several minutes and cost ~$0.30–0.60")

        let result = try await harness.compareVariantsLive(
            baselineVariant: Self.baselineVariant,
            candidateVariant: Self.terseVariant,
            scenarios: EvalVaultFixtures.diverseScenarios,
            provider: provider
        )

        let baselineURL = try store.save(result.baselineReport)
        let candidateURL = try store.save(result.candidateReport)

        let reportsDir = store.directory.appendingPathComponent("reports", isDirectory: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let summaryURL = reportsDir.appendingPathComponent("\(timestamp)-COMPARISON-diverse-20.md")

        // Build rich summary with per-scenario breakdown
        var md = result.comparison.summary
        md += "\n\n## Per-scenario breakdown\n\n"
        md += "| Scenario | Baseline | Candidate | Tokens Δ | Turns Δ |\n"
        md += "|----------|:--------:|:---------:|:--------:|:-------:|\n"
        for delta in result.comparison.scenarioDeltas {
            let bMark = delta.baselinePassed ? "✓" : "✗"
            let cMark = delta.candidatePassed ? "✓" : "✗"
            let tokenStr = delta.tokenDelta >= 0 ? "+\(delta.tokenDelta)" : "\(delta.tokenDelta)"
            let turnStr = delta.turnDelta >= 0 ? "+\(delta.turnDelta)" : "\(delta.turnDelta)"
            md += "| \(delta.scenarioID) | \(bMark) | \(cMark) | \(tokenStr) | \(turnStr) |\n"
        }
        md += "\n## Aggregate\n\n"
        md += "- Baseline: **\(result.baselineReport.aggregate.passedScenarios)/\(result.baselineReport.aggregate.totalScenarios)** passed, **\(result.baselineReport.aggregate.totalTokens)** tokens\n"
        md += "- Candidate: **\(result.candidateReport.aggregate.passedScenarios)/\(result.candidateReport.aggregate.totalScenarios)** passed, **\(result.candidateReport.aggregate.totalTokens)** tokens\n"
        try md.write(to: summaryURL, atomically: true, encoding: .utf8)

        // Print to stdout
        print("\n" + String(repeating: "=", count: 70))
        print(md)
        print(String(repeating: "=", count: 70) + "\n")

        print("[DIVERSE] Reports written to:")
        print("  baseline:   \(baselineURL.path)")
        print("  candidate:  \(candidateURL.path)")
        print("  comparison: \(summaryURL.path)")

        #expect(result.baselineReport.scenarioResults.count == EvalVaultFixtures.diverseScenarios.count)
        #expect(result.candidateReport.scenarioResults.count == EvalVaultFixtures.diverseScenarios.count)
    }
}

private struct SkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
