import Foundation

/// Events emitted by the agent loop, consumed by UI to show progress.
public enum AgentEvent: Sendable {
    case agentStart
    case turnStart(turnIndex: Int)
    case textToken(String)
    case toolStart(name: String, arguments: String)
    case toolEnd(name: String, result: ToolResult)
    case turnEnd(turnIndex: Int)
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
