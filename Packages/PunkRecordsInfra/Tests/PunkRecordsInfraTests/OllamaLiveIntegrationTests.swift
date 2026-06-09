import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

/// LIVE integration test against a locally running Ollama server.
///
/// Unlike `LocalProviderEncodingTests` (which exercise only the pure
/// encoders/decoders against hand-built JSON), these drive the *real* wire
/// path: HTTP to `/api/tags` and `/api/chat`, response decoding, and
/// nanosecond-metric extraction into `InferenceStats`.
///
/// They auto-skip (return without failing) when no Ollama is reachable at the
/// default endpoint, so the suite is a no-op in CI / on machines without
/// `ollama serve` running, but provides genuine end-to-end coverage on a dev
/// box with a model installed.
@Suite("Ollama live integration")
struct OllamaLiveIntegrationTests {
    private static let endpoint = URL(string: "http://localhost:11434")!

    /// Probe the server. Returns its advertised models, or `nil` when nothing
    /// answers — the caller treats `nil` as "skip".
    private func reachableModels() async -> [LocalModel]? {
        let result = await OllamaProvider(endpoint: Self.endpoint).validate()
        return result.isReachable ? result.models : nil
    }

    @Test("Lists at least one installed model")
    func listsModels() async {
        guard let models = await reachableModels() else {
            print("⏭️  Ollama not reachable at \(Self.endpoint) — skipping live test")
            return
        }
        #expect(!models.isEmpty, "A running Ollama should advertise ≥1 model")
    }

    @Test("Completes a prompt and returns server-native inference stats")
    func completesWithNativeStats() async throws {
        guard let first = await reachableModels()?.first else {
            print("⏭️  Ollama not reachable — skipping live test")
            return
        }

        let provider = OllamaProvider(endpoint: Self.endpoint, modelID: first.id)
        #expect(await provider.isAvailable(), "A reachable provider with a model set should be available")

        let response = try await provider.complete(
            LLMRequest(userPrompt: "Reply with exactly the word: pong", streamResponse: false)
        )

        #expect(!response.text.isEmpty, "Live completion should return non-empty text")

        // The native /api/chat path must attach server-accurate metrics.
        let stats = try #require(response.stats, "Ollama should attach native inference stats")
        #expect(stats.source == .ollamaNative)
        #expect(stats.hasAnyMetric)
        #expect((stats.tokensPerSecond ?? 0) > 0, "Native stats should report generation throughput")
        #expect((stats.completionTokens ?? 0) > 0, "Native stats should report generated token count")

        let tps = stats.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        let ttft = stats.timeToFirstToken.map { String(format: "%.3fs", $0) } ?? "—"
        print("✅ Ollama live: model=\(first.id) tok/s=\(tps) ttft=\(ttft) "
            + "text=\"\(response.text.prefix(40))\"")
    }
}
