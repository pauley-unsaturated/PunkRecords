import Foundation

/// Pure formatting of an ``EvalReport`` into a human-readable run summary,
/// optionally with a trend delta against the previous stored report.
///
/// Kept as a pure function (no I/O) so it can be unit-tested by feeding two
/// fabricated reports and asserting the rendered text — the flywheel driver
/// merely `print`s the result.
public enum EvalReportPrinter {

    /// Render a run summary: per-scenario pass/fail, overall pass-rate, mean tool
    /// calls, token estimate, and — when `previous` is supplied — a trend delta
    /// (pass-rate, mean tokens, mean turns) versus that earlier report.
    public static func summary(
        report: EvalReport,
        previous: EvalReport? = nil,
        variantName: String? = nil
    ) -> String {
        let agg = report.aggregate
        var lines: [String] = []

        let title = variantName.map { "\(report.promptVariantID) (\($0))" } ?? report.promptVariantID
        lines.append("=== Flywheel Run: \(title) ===")
        lines.append("Timestamp: \(isoFormatter.string(from: report.timestamp))")
        lines.append("Scenarios: \(agg.totalScenarios)")
        lines.append("")

        lines.append("Per-scenario:")
        for result in report.scenarioResults {
            let status = result.success ? "PASS" : "FAIL"
            lines.append("  [\(status)] \(result.scenarioID)"
                + " — turns=\(result.metrics.turnCount)"
                + " tools=\(result.metrics.toolCallCount)"
                + " tokens=\(result.metrics.totalTokens.totalTokens)")
            if !result.success {
                for reason in result.failureReasons {
                    lines.append("           ↳ \(reason)")
                }
            }
        }
        lines.append("")

        let meanToolCalls = agg.totalScenarios == 0 ? 0 :
            Double(report.scenarioResults.reduce(0) { $0 + $1.metrics.toolCallCount }) / Double(agg.totalScenarios)

        lines.append("Overall:")
        lines.append("  Pass rate: \(agg.passedScenarios)/\(agg.totalScenarios)"
            + " (\(fmt(agg.taskCompletionRate * 100))%)")
        lines.append("  Mean tool calls: \(fmt(meanToolCalls))")
        lines.append("  Mean tokens/task: \(fmt(agg.averageTokensPerTask))")
        lines.append("  Total tokens (est): \(agg.totalTokens)")

        if let previous {
            lines.append("")
            lines.append("Trend vs previous (\(isoFormatter.string(from: previous.timestamp))):")
            lines.append(deltaLine("Pass rate",
                                   base: previous.aggregate.taskCompletionRate,
                                   candidate: agg.taskCompletionRate,
                                   higherIsBetter: true))
            lines.append(deltaLine("Mean tokens/task",
                                   base: previous.aggregate.averageTokensPerTask,
                                   candidate: agg.averageTokensPerTask,
                                   higherIsBetter: false))
            lines.append(deltaLine("Mean turns/task",
                                   base: previous.aggregate.averageTurnsPerTask,
                                   candidate: agg.averageTurnsPerTask,
                                   higherIsBetter: false))
        }

        return lines.joined(separator: "\n")
    }

    /// One trend row rendered via ``MetricDelta`` so the arrow/direction logic
    /// stays consistent with variant comparisons.
    private static func deltaLine(_ label: String, base: Double, candidate: Double, higherIsBetter: Bool) -> String {
        let delta = MetricDelta(metric: label, baseline: base, candidate: candidate, higherIsBetter: higherIsBetter)
        let arrow: String
        switch delta.direction {
        case .better: arrow = "↑"
        case .worse: arrow = "↓"
        case .unchanged: arrow = "–"
        }
        let pct = delta.percentChange.isFinite ? String(format: "%+.1f%%", delta.percentChange * 100) : "∞"
        return "  \(label): \(fmt(base)) → \(fmt(candidate)) \(arrow) (\(pct))"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// `ISO8601DateFormatter` is thread-safe for reading even though Swift 6 can't prove it.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
