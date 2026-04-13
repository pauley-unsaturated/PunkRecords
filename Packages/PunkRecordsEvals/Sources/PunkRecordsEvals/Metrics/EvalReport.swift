import Foundation

/// Result of evaluating a single scenario.
public struct ScenarioResult: Codable, Sendable {
    public let scenarioID: String
    public let scenarioName: String
    public let success: Bool
    public let metrics: TaskMetrics
    public let failureReasons: [String]
    public let finalOutput: String

    public init(scenarioID: String, scenarioName: String, success: Bool,
                metrics: TaskMetrics, failureReasons: [String], finalOutput: String) {
        self.scenarioID = scenarioID
        self.scenarioName = scenarioName
        self.success = success
        self.metrics = metrics
        self.failureReasons = failureReasons
        self.finalOutput = finalOutput
    }
}

/// Aggregate metrics across all scenarios in a run.
public struct AggregateMetrics: Codable, Sendable {
    public let totalScenarios: Int
    public let passedScenarios: Int
    public let taskCompletionRate: Double
    public let averageTokensPerTask: Double
    public let averageTurnsPerTask: Double
    public let averageCacheHitRate: Double
    public let totalTokens: Int

    public init(results: [ScenarioResult]) {
        self.totalScenarios = results.count
        self.passedScenarios = results.filter(\.success).count
        self.taskCompletionRate = results.isEmpty ? 0 : Double(passedScenarios) / Double(totalScenarios)
        self.averageTokensPerTask = results.isEmpty ? 0 :
            Double(results.reduce(0) { $0 + $1.metrics.totalTokens.totalTokens }) / Double(results.count)
        self.averageTurnsPerTask = results.isEmpty ? 0 :
            Double(results.reduce(0) { $0 + $1.metrics.turnCount }) / Double(results.count)
        self.averageCacheHitRate = results.isEmpty ? 0 :
            results.reduce(0.0) { $0 + $1.metrics.totalTokens.cacheHitRate } / Double(results.count)
        self.totalTokens = results.reduce(0) { $0 + $1.metrics.totalTokens.totalTokens }
    }
}

/// Full report for one eval run, serializable to JSON for trend tracking.
public struct EvalReport: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let promptVariantID: String
    public let scenarioResults: [ScenarioResult]
    public let aggregate: AggregateMetrics

    public init(promptVariantID: String = "default", results: [ScenarioResult]) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.promptVariantID = promptVariantID
        self.scenarioResults = results
        self.aggregate = AggregateMetrics(results: results)
    }

    /// Serialize to JSON data for storage.
    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Deserialize from JSON data.
    public static func fromJSON(_ data: Data) throws -> EvalReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalReport.self, from: data)
    }
}
