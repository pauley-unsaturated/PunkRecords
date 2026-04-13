import Foundation
import PunkRecordsCore

/// Collects metrics from AgentEvent streams during an eval run.
public actor MetricsCollector {
    private var currentTurnIndex = 0
    private var currentTurnStart: ContinuousClock.Instant?
    private var currentTurnTokens = TokenMetrics.zero
    private var currentToolCalls: [ToolCallRecord] = []
    private var currentToolStart: ContinuousClock.Instant?
    private var currentToolName: String?
    private var completedTurns: [TurnMetrics] = []
    private var finalText = ""

    public init() {}

    /// Process a stream of agent events and collect metrics.
    public func collect(
        from stream: AsyncThrowingStream<AgentEvent, Error>,
        scenarioID: String
    ) async throws -> (TaskMetrics, String) {
        var success = true

        for try await event in stream {
            switch event {
            case .agentStart:
                break
            case .turnStart(let index):
                currentTurnIndex = index
                currentTurnStart = ContinuousClock.now
                currentTurnTokens = .zero
                currentToolCalls = []
            case .textToken(let token):
                finalText += token
            case .toolStart(let name, _):
                currentToolName = name
                currentToolStart = ContinuousClock.now
            case .toolEnd(let name, let result):
                let elapsed = currentToolStart.map { ContinuousClock.now - $0 } ?? .zero
                currentToolCalls.append(ToolCallRecord(
                    toolName: name,
                    latencyMS: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
                    isError: result.isError
                ))
                currentToolStart = nil
                currentToolName = nil
            case .turnEnd:
                let elapsed = currentTurnStart.map { ContinuousClock.now - $0 } ?? .zero
                completedTurns.append(TurnMetrics(
                    turnIndex: currentTurnIndex,
                    tokens: currentTurnTokens,
                    latencyMS: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
                    toolCalls: currentToolCalls
                ))
            case .done:
                break
            case .error(let err):
                if case .cancelled = err {
                    success = false
                } else if case .maxIterationsExceeded = err {
                    success = false
                }
            }
        }

        let metrics = TaskMetrics(scenarioID: scenarioID, turns: completedTurns, success: success)
        return (metrics, finalText)
    }

    /// Record token usage for the current turn (called by InstrumentedProvider).
    public func recordTurnTokens(_ tokens: TokenMetrics) {
        currentTurnTokens = currentTurnTokens + tokens
    }
}
