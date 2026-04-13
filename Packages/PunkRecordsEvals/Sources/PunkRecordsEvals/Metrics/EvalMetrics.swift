import Foundation
import PunkRecordsCore

/// Token metrics for a single LLM call, including cache data.
public struct TokenMetrics: Codable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }

    public var cacheHitRate: Double {
        let total = cacheCreationInputTokens + cacheReadInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total)
    }

    public init(from usage: TokenUsage?) {
        self.promptTokens = usage?.promptTokens ?? 0
        self.completionTokens = usage?.completionTokens ?? 0
        self.cacheCreationInputTokens = usage?.cacheCreationInputTokens ?? 0
        self.cacheReadInputTokens = usage?.cacheReadInputTokens ?? 0
    }

    public init(promptTokens: Int = 0, completionTokens: Int = 0,
                cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public static func + (lhs: TokenMetrics, rhs: TokenMetrics) -> TokenMetrics {
        TokenMetrics(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    public static let zero = TokenMetrics()
}

/// Metrics for a single tool call.
public struct ToolCallRecord: Codable, Sendable {
    public let toolName: String
    public let latencyMS: Int
    public let isError: Bool

    public init(toolName: String, latencyMS: Int, isError: Bool) {
        self.toolName = toolName
        self.latencyMS = latencyMS
        self.isError = isError
    }
}

/// Metrics for a single LLM turn (one request/response cycle).
public struct TurnMetrics: Codable, Sendable {
    public let turnIndex: Int
    public let tokens: TokenMetrics
    public let latencyMS: Int
    public let toolCalls: [ToolCallRecord]

    public init(turnIndex: Int, tokens: TokenMetrics, latencyMS: Int, toolCalls: [ToolCallRecord]) {
        self.turnIndex = turnIndex
        self.tokens = tokens
        self.latencyMS = latencyMS
        self.toolCalls = toolCalls
    }
}

/// Full metrics for one scenario run.
public struct TaskMetrics: Codable, Sendable {
    public let scenarioID: String
    public let turns: [TurnMetrics]
    public let totalTokens: TokenMetrics
    public let totalLatencyMS: Int
    public let turnCount: Int
    public let toolCallCount: Int
    public let success: Bool
    public let timestamp: Date

    public init(scenarioID: String, turns: [TurnMetrics], success: Bool) {
        self.scenarioID = scenarioID
        self.turns = turns
        self.totalTokens = turns.reduce(TokenMetrics.zero) { $0 + $1.tokens }
        self.totalLatencyMS = turns.reduce(0) { $0 + $1.latencyMS }
        self.turnCount = turns.count
        self.toolCallCount = turns.reduce(0) { $0 + $1.toolCalls.count }
        self.success = success
        self.timestamp = Date()
    }
}
