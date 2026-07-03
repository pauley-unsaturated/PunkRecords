import Foundation

/// Events emitted by the agent loop, consumed by UI to show progress.
public enum AgentEvent: Sendable {
    case agentStart
    case turnStart(turnIndex: Int)
    case textToken(String)
    case toolStart(name: String, arguments: String)
    case toolEnd(name: String, result: ToolResult)
    /// Ends one model round. `usage` is the round's token accounting when the
    /// producer can supply it — currently ``TokenEstimator`` heuristics from
    /// the session runner (AnyLanguageModel reports no real usage), `nil` when
    /// unknown.
    case turnEnd(turnIndex: Int, usage: TokenUsage?)
    case done(finalText: String)
    case error(AgentError)
}

public enum AgentError: Error, Sendable {
    case maxIterationsExceeded(Int)
    case toolNotFound(String)
    case toolExecutionFailed(toolName: String, underlying: String)
    case providerError(String)
    case cancelled
}
