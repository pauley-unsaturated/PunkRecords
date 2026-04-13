import Foundation

/// Delta between a single metric across baseline and candidate runs.
public struct MetricDelta: Codable, Sendable {
    public let metric: String
    public let baselineValue: Double
    public let candidateValue: Double
    public let absoluteDelta: Double
    public let percentChange: Double  // (candidate - baseline) / baseline

    /// Is the delta "good"? Depends on the metric — higher is better for success rates,
    /// lower is better for tokens and turns.
    public let direction: Direction

    public enum Direction: String, Codable, Sendable {
        case better, worse, unchanged
    }

    public init(metric: String, baseline: Double, candidate: Double, higherIsBetter: Bool) {
        self.metric = metric
        self.baselineValue = baseline
        self.candidateValue = candidate
        self.absoluteDelta = candidate - baseline

        if baseline == 0 {
            self.percentChange = candidate == 0 ? 0 : .infinity
        } else {
            self.percentChange = (candidate - baseline) / baseline
        }

        // Use a small threshold to avoid flagging noise as movement.
        let epsilon = 0.001
        if abs(absoluteDelta) < epsilon {
            self.direction = .unchanged
        } else if higherIsBetter {
            self.direction = candidate > baseline ? .better : .worse
        } else {
            self.direction = candidate < baseline ? .better : .worse
        }
    }
}

/// Per-scenario before/after.
public struct ScenarioDelta: Codable, Sendable {
    public let scenarioID: String
    public let baselinePassed: Bool
    public let candidatePassed: Bool
    public let tokenDelta: Int        // candidate - baseline
    public let turnDelta: Int
    public let cacheHitRateDelta: Double

    /// Scenario regressed from passing to failing.
    public var regressed: Bool { baselinePassed && !candidatePassed }
    /// Scenario recovered from failing to passing.
    public var recovered: Bool { !baselinePassed && candidatePassed }
}

/// Result of comparing two eval reports (baseline vs candidate prompt variant).
public struct VariantComparison: Codable, Sendable {
    public let baselineVariantID: String
    public let candidateVariantID: String
    public let baselineReportID: String
    public let candidateReportID: String
    public let metricDeltas: [MetricDelta]
    public let scenarioDeltas: [ScenarioDelta]
    public let regressedScenarios: [String]   // IDs of scenarios that regressed
    public let recoveredScenarios: [String]   // IDs of scenarios that recovered
    public let overallRecommendation: Recommendation

    public enum Recommendation: String, Codable, Sendable {
        case promoteCandidate   // Clear win, no regressions
        case candidateBetter    // Net positive but watch-outs
        case mixed              // Some better, some worse
        case keepBaseline       // Candidate is worse overall
        case insufficientData   // Can't tell
    }

    /// Human-readable summary for printing in reports.
    public var summary: String {
        var lines: [String] = []
        lines.append("# Variant Comparison: \(baselineVariantID) → \(candidateVariantID)")
        lines.append("")
        lines.append("**Recommendation:** \(overallRecommendation.rawValue)")
        lines.append("")
        lines.append("## Metrics")
        for d in metricDeltas {
            let arrow: String
            switch d.direction {
            case .better: arrow = "↑"
            case .worse: arrow = "↓"
            case .unchanged: arrow = "–"
            }
            let pct = d.percentChange.isFinite ? String(format: "%+.1f%%", d.percentChange * 100) : "∞"
            lines.append("- **\(d.metric)** \(arrow) \(String(format: "%.2f", d.baselineValue)) → \(String(format: "%.2f", d.candidateValue)) (\(pct))")
        }
        if !regressedScenarios.isEmpty {
            lines.append("")
            lines.append("## ⚠️ Regressed")
            for id in regressedScenarios { lines.append("- \(id)") }
        }
        if !recoveredScenarios.isEmpty {
            lines.append("")
            lines.append("## ✓ Recovered")
            for id in recoveredScenarios { lines.append("- \(id)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Compares eval reports across prompt variants.
public struct VariantComparator: Sendable {

    public init() {}

    public func compare(baseline: EvalReport, candidate: EvalReport) -> VariantComparison {
        let b = baseline.aggregate
        let c = candidate.aggregate

        // Aggregate metric deltas with sensible directionality
        let metricDeltas: [MetricDelta] = [
            MetricDelta(metric: "taskCompletionRate",
                        baseline: b.taskCompletionRate, candidate: c.taskCompletionRate,
                        higherIsBetter: true),
            MetricDelta(metric: "averageTokensPerTask",
                        baseline: b.averageTokensPerTask, candidate: c.averageTokensPerTask,
                        higherIsBetter: false),
            MetricDelta(metric: "averageTurnsPerTask",
                        baseline: b.averageTurnsPerTask, candidate: c.averageTurnsPerTask,
                        higherIsBetter: false),
            MetricDelta(metric: "averageCacheHitRate",
                        baseline: b.averageCacheHitRate, candidate: c.averageCacheHitRate,
                        higherIsBetter: true),
            MetricDelta(metric: "totalTokens",
                        baseline: Double(b.totalTokens), candidate: Double(c.totalTokens),
                        higherIsBetter: false),
        ]

        // Per-scenario deltas — match by scenarioID
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.scenarioResults.map { ($0.scenarioID, $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.scenarioResults.map { ($0.scenarioID, $0) })
        let sharedIDs = Set(baselineByID.keys).intersection(candidateByID.keys)

        var scenarioDeltas: [ScenarioDelta] = []
        var regressed: [String] = []
        var recovered: [String] = []

        for id in sharedIDs.sorted() {
            guard let b = baselineByID[id], let c = candidateByID[id] else { continue }
            let delta = ScenarioDelta(
                scenarioID: id,
                baselinePassed: b.success,
                candidatePassed: c.success,
                tokenDelta: c.metrics.totalTokens.totalTokens - b.metrics.totalTokens.totalTokens,
                turnDelta: c.metrics.turnCount - b.metrics.turnCount,
                cacheHitRateDelta: c.metrics.totalTokens.cacheHitRate - b.metrics.totalTokens.cacheHitRate
            )
            scenarioDeltas.append(delta)
            if delta.regressed { regressed.append(id) }
            if delta.recovered { recovered.append(id) }
        }

        // Overall recommendation — pragmatic rules, not statistical
        let recommendation = recommend(
            metricDeltas: metricDeltas,
            regressedCount: regressed.count,
            recoveredCount: recovered.count,
            sharedScenarios: sharedIDs.count
        )

        return VariantComparison(
            baselineVariantID: baseline.promptVariantID,
            candidateVariantID: candidate.promptVariantID,
            baselineReportID: baseline.id,
            candidateReportID: candidate.id,
            metricDeltas: metricDeltas,
            scenarioDeltas: scenarioDeltas,
            regressedScenarios: regressed,
            recoveredScenarios: recovered,
            overallRecommendation: recommendation
        )
    }

    private func recommend(
        metricDeltas: [MetricDelta],
        regressedCount: Int,
        recoveredCount: Int,
        sharedScenarios: Int
    ) -> VariantComparison.Recommendation {
        if sharedScenarios == 0 { return .insufficientData }
        if regressedCount > 0 && recoveredCount == 0 { return .keepBaseline }

        let better = metricDeltas.filter { $0.direction == .better }.count
        let worse = metricDeltas.filter { $0.direction == .worse }.count

        // Completion rate regression is a hard block
        if let completion = metricDeltas.first(where: { $0.metric == "taskCompletionRate" }),
           completion.direction == .worse {
            return .keepBaseline
        }

        if regressedCount == 0 && better > worse { return .promoteCandidate }
        if better > worse { return .candidateBetter }
        if worse > better { return .keepBaseline }
        return .mixed
    }
}
