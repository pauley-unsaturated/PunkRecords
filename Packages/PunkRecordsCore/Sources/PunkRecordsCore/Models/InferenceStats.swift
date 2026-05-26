import Foundation

/// Per-response inference performance metrics, surfaced for local-LLM providers.
///
/// All rate fields are tokens/second; durations are seconds. Any field may be
/// `nil` when the underlying provider doesn't report it (e.g. LM Studio's
/// OpenAI-compatible endpoint gives no server-side timing, so prefill/TTFT
/// require client-side streaming to measure).
public struct InferenceStats: Sendable, Codable, Equatable {
    /// Where the numbers came from — affects how much we trust precision.
    public enum Source: String, Sendable, Codable {
        /// Server-reported nanosecond timers (Ollama `/api/chat`).
        case ollamaNative
        /// Wall-clock measured on the client during streaming/completion.
        case clientSide
    }

    /// Seconds from request send to the first generated token.
    public let timeToFirstToken: TimeInterval?
    /// Prompt (prefill) throughput, in tokens/second.
    public let prefillRate: Double?
    /// Generation throughput, in tokens/second.
    public let tokensPerSecond: Double?
    /// Cold-start model load time, in seconds (Ollama reports this separately).
    public let loadDuration: TimeInterval?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let source: Source

    public init(
        timeToFirstToken: TimeInterval? = nil,
        prefillRate: Double? = nil,
        tokensPerSecond: Double? = nil,
        loadDuration: TimeInterval? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        source: Source
    ) {
        self.timeToFirstToken = timeToFirstToken
        self.prefillRate = prefillRate
        self.tokensPerSecond = tokensPerSecond
        self.loadDuration = loadDuration
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.source = source
    }

    /// True when there's at least one measured field worth showing.
    public var hasAnyMetric: Bool {
        timeToFirstToken != nil || prefillRate != nil || tokensPerSecond != nil
    }
}

public extension InferenceStats {
    private static let nanosPerSecond = 1_000_000_000.0

    /// Build stats from Ollama's native `/api/chat` (non-streaming) response,
    /// whose duration fields are integer **nanoseconds**.
    ///
    /// Ollama splits the pre-generation cost into `load_duration` (model load)
    /// and `prompt_eval_duration` (prefill). Time-to-first-token is the sum of
    /// the two, since both elapse before any output token is produced.
    static func fromOllama(
        promptEvalCount: Int?,
        promptEvalDurationNanos: Int?,
        evalCount: Int?,
        evalDurationNanos: Int?,
        loadDurationNanos: Int?
    ) -> InferenceStats {
        func seconds(_ nanos: Int?) -> TimeInterval? {
            guard let nanos, nanos > 0 else { return nil }
            return Double(nanos) / nanosPerSecond
        }
        func rate(_ count: Int?, _ nanos: Int?) -> Double? {
            guard let count, count > 0, let secs = seconds(nanos) else { return nil }
            return Double(count) / secs
        }

        let load = seconds(loadDurationNanos)
        let prefill = seconds(promptEvalDurationNanos)
        let ttft: TimeInterval?
        if load != nil || prefill != nil {
            ttft = (load ?? 0) + (prefill ?? 0)
        } else {
            ttft = nil
        }

        return InferenceStats(
            timeToFirstToken: ttft,
            prefillRate: rate(promptEvalCount, promptEvalDurationNanos),
            tokensPerSecond: rate(evalCount, evalDurationNanos),
            loadDuration: load,
            promptTokens: promptEvalCount,
            completionTokens: evalCount,
            source: .ollamaNative
        )
    }

    /// Build stats from client-measured wall-clock timing. `firstTokenAt` is the
    /// instant the first streamed token arrived; pass `nil` for non-streaming
    /// calls (TTFT and prefill rate then can't be computed and stay `nil`).
    static func fromClientTiming(
        requestStart: Date,
        firstTokenAt: Date?,
        completedAt: Date,
        promptTokens: Int?,
        completionTokens: Int?
    ) -> InferenceStats {
        let ttft = firstTokenAt.map { $0.timeIntervalSince(requestStart) }

        let generationStart = firstTokenAt ?? requestStart
        let generationElapsed = completedAt.timeIntervalSince(generationStart)
        let tps: Double?
        if let completionTokens, completionTokens > 0, generationElapsed > 0 {
            tps = Double(completionTokens) / generationElapsed
        } else {
            tps = nil
        }

        let prefill: Double?
        if let promptTokens, promptTokens > 0, let ttft, ttft > 0 {
            prefill = Double(promptTokens) / ttft
        } else {
            prefill = nil
        }

        return InferenceStats(
            timeToFirstToken: ttft,
            prefillRate: prefill,
            tokensPerSecond: tps,
            loadDuration: nil,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            source: .clientSide
        )
    }
}
