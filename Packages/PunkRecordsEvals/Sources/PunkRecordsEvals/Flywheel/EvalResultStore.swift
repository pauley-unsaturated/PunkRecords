import Foundation

/// File-based store for eval reports and prompt variants.
/// Reports live at `{directory}/reports/{timestamp}-{variant-id}.json`.
/// Variants live at `{directory}/variants/{variant-id}.json`.
public struct EvalResultStore: Sendable {
    public let directory: URL

    public static let defaultDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".punkrecords/eval-results", isDirectory: true)
    }()

    public init(directory: URL = EvalResultStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: - Reports

    /// Save a report with a timestamped filename. Returns the written URL.
    @discardableResult
    public func save(_ report: EvalReport) throws -> URL {
        let reportsDir = directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: report.timestamp).replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)-\(report.promptVariantID).json"
        let url = reportsDir.appendingPathComponent(filename)
        try report.toJSON().write(to: url)
        return url
    }

    /// Load every report in the store, sorted by timestamp ascending.
    public func loadAll() throws -> [EvalReport] {
        let reportsDir = directory.appendingPathComponent("reports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: reportsDir.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let reports = urls.compactMap { url -> EvalReport? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? EvalReport.fromJSON(data)
        }
        return reports.sorted { $0.timestamp < $1.timestamp }
    }

    /// Load reports filtered by prompt variant ID.
    public func loadForVariant(_ variantID: String) throws -> [EvalReport] {
        try loadAll().filter { $0.promptVariantID == variantID }
    }

    /// The most recent report for a given variant, or nil if none.
    public func latestForVariant(_ variantID: String) throws -> EvalReport? {
        try loadForVariant(variantID).last
    }

    // MARK: - Variants

    @discardableResult
    public func save(_ variant: PromptVariant) throws -> URL {
        let variantsDir = directory.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        let url = variantsDir.appendingPathComponent("\(variant.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(variant).write(to: url)
        return url
    }

    public func loadVariant(_ id: String) throws -> PromptVariant? {
        let url = directory.appendingPathComponent("variants/\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PromptVariant.self, from: data)
    }

    public func loadAllVariants() throws -> [PromptVariant] {
        let variantsDir = directory.appendingPathComponent("variants", isDirectory: true)
        guard FileManager.default.fileExists(atPath: variantsDir.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: variantsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PromptVariant.self, from: data)
        }
    }

    // MARK: - Trend Queries

    /// A single point in a metric's time series for trend analysis.
    public struct TrendPoint: Sendable {
        public let timestamp: Date
        public let variantID: String
        public let value: Double
    }

    /// Return a time series of a metric across all reports, optionally for a specific scenario.
    ///
    /// Supported metric keys: "taskCompletionRate", "averageTokensPerTask",
    /// "averageTurnsPerTask", "averageCacheHitRate", "totalTokens".
    public func trend(metric: String, scenarioID: String? = nil) throws -> [TrendPoint] {
        let reports = try loadAll()
        return reports.compactMap { report -> TrendPoint? in
            let value: Double?
            if let scenarioID {
                // Per-scenario metric
                guard let result = report.scenarioResults.first(where: { $0.scenarioID == scenarioID }) else {
                    return nil
                }
                switch metric {
                case "totalTokens":
                    value = Double(result.metrics.totalTokens.totalTokens)
                case "turnCount":
                    value = Double(result.metrics.turnCount)
                case "cacheHitRate":
                    value = result.metrics.totalTokens.cacheHitRate
                case "success":
                    value = result.success ? 1.0 : 0.0
                default:
                    value = nil
                }
            } else {
                // Aggregate metric
                switch metric {
                case "taskCompletionRate": value = report.aggregate.taskCompletionRate
                case "averageTokensPerTask": value = report.aggregate.averageTokensPerTask
                case "averageTurnsPerTask": value = report.aggregate.averageTurnsPerTask
                case "averageCacheHitRate": value = report.aggregate.averageCacheHitRate
                case "totalTokens": value = Double(report.aggregate.totalTokens)
                default: value = nil
                }
            }
            guard let v = value else { return nil }
            return TrendPoint(timestamp: report.timestamp, variantID: report.promptVariantID, value: v)
        }
    }
}
