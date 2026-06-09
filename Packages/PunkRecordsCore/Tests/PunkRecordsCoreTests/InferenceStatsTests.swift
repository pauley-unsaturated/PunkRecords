import XCTest
@testable import PunkRecordsCore

final class InferenceStatsTests: XCTestCase {
    private let nanos = 1_000_000_000

    // MARK: - Ollama native metrics

    func testOllamaRatesAndTTFT() {
        // 10 prompt tokens prefilled in 0.5s → 20 tok/s.
        // 40 generated tokens in 2s → 20 tok/s.
        // load 0.25s + prefill 0.5s → TTFT 0.75s.
        let stats = InferenceStats.fromOllama(
            promptEvalCount: 10,
            promptEvalDurationNanos: nanos / 2,
            evalCount: 40,
            evalDurationNanos: 2 * nanos,
            loadDurationNanos: nanos / 4
        )

        XCTAssertEqual(stats.source, .ollamaNative)
        XCTAssertEqual(stats.prefillRate!, 20, accuracy: 0.001)
        XCTAssertEqual(stats.tokensPerSecond!, 20, accuracy: 0.001)
        XCTAssertEqual(stats.loadDuration!, 0.25, accuracy: 0.001)
        XCTAssertEqual(stats.timeToFirstToken!, 0.75, accuracy: 0.001)
        XCTAssertEqual(stats.promptTokens, 10)
        XCTAssertEqual(stats.completionTokens, 40)
    }

    func testOllamaTTFTWithoutLoadDuration() {
        // Warm model: no load time reported, TTFT is just the prefill duration.
        let stats = InferenceStats.fromOllama(
            promptEvalCount: 5,
            promptEvalDurationNanos: nanos,
            evalCount: 10,
            evalDurationNanos: nanos,
            loadDurationNanos: nil
        )
        XCTAssertEqual(stats.timeToFirstToken!, 1.0, accuracy: 0.001)
        XCTAssertNil(stats.loadDuration)
    }

    func testOllamaZeroDurationsYieldNilRates() {
        // A zero duration must not divide-by-zero into infinity.
        let stats = InferenceStats.fromOllama(
            promptEvalCount: 10,
            promptEvalDurationNanos: 0,
            evalCount: 0,
            evalDurationNanos: 0,
            loadDurationNanos: 0
        )
        XCTAssertNil(stats.prefillRate)
        XCTAssertNil(stats.tokensPerSecond)
        XCTAssertNil(stats.timeToFirstToken)
        XCTAssertNil(stats.loadDuration)
    }

    func testOllamaMissingCountsYieldNilRates() {
        let stats = InferenceStats.fromOllama(
            promptEvalCount: nil,
            promptEvalDurationNanos: nanos,
            evalCount: nil,
            evalDurationNanos: nanos,
            loadDurationNanos: nil
        )
        XCTAssertNil(stats.prefillRate)
        XCTAssertNil(stats.tokensPerSecond)
    }

    // MARK: - Client-side timing

    func testClientSideStreamingTiming() {
        let start = Date(timeIntervalSince1970: 1000)
        let firstToken = Date(timeIntervalSince1970: 1000.5) // TTFT 0.5s
        let done = Date(timeIntervalSince1970: 1002.5)        // 2s of generation

        let stats = InferenceStats.fromClientTiming(
            requestStart: start,
            firstTokenAt: firstToken,
            completedAt: done,
            promptTokens: 100,
            completionTokens: 50
        )

        XCTAssertEqual(stats.source, .clientSide)
        XCTAssertEqual(stats.timeToFirstToken!, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.prefillRate!, 200, accuracy: 0.001)      // 100 / 0.5
        XCTAssertEqual(stats.tokensPerSecond!, 25, accuracy: 0.001)   // 50 / 2.0
    }

    func testClientSideNonStreamingHasNoTTFT() {
        // No first-token timestamp (non-streaming): TTFT and prefill are unknown,
        // but TPS is still derivable from total elapsed.
        let start = Date(timeIntervalSince1970: 1000)
        let done = Date(timeIntervalSince1970: 1004) // 4s total

        let stats = InferenceStats.fromClientTiming(
            requestStart: start,
            firstTokenAt: nil,
            completedAt: done,
            promptTokens: 100,
            completionTokens: 40
        )

        XCTAssertNil(stats.timeToFirstToken)
        XCTAssertNil(stats.prefillRate)
        XCTAssertEqual(stats.tokensPerSecond!, 10, accuracy: 0.001) // 40 / 4
    }

    func testHasAnyMetric() {
        let empty = InferenceStats(source: .clientSide)
        XCTAssertFalse(empty.hasAnyMetric)

        let withTPS = InferenceStats(tokensPerSecond: 12, source: .clientSide)
        XCTAssertTrue(withTPS.hasAnyMetric)
    }
}
