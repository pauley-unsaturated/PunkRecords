import Testing
import Foundation
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport
import PunkRecordsEvals

/// Live agent evals that hit the real Anthropic API.
/// Tagged `.eval` so they only run intentionally — they cost real money.
///
/// Results are written as JSON to ~/.punkrecords/eval-results/{timestamp}-live.json
@Suite("Live Agent Evals", .tags(.eval), .serialized)
struct LiveAgentEvals {

    static let keychain = KeychainService()

    static func requireAPIKey() throws {
        guard let key = try? keychain.apiKey(for: "anthropic"), key != nil else {
            throw SkipError("No Anthropic API key in keychain — skipping live eval")
        }
    }

    static func resultsDirectory() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".punkrecords/eval-results", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeReport(_ report: EvalReport, suffix: String) throws -> URL {
        let dir = try resultsDirectory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)-\(suffix).json"
        let url = dir.appendingPathComponent(filename)
        let data = try report.toJSON()
        try data.write(to: url)
        return url
    }

    // MARK: - Cache Behavior Test (direct provider calls)

    /// Sends 3 sequential queries with identical system prompt context.
    /// Validates that prompt caching kicks in: first call creates cache, subsequent calls read it.
    @Test("Live cache: sequential queries should hit the cache on call 2+")
    func liveCacheBehavior() async throws {
        try Self.requireAPIKey()

        let provider = AnthropicProvider(keychainService: Self.keychain)

        // Build a substantial system prompt that exceeds Sonnet 4.6's 2048-token cache minimum.
        // Previous run used count: 20 → ~1700 tokens, which is BELOW the threshold and silently
        // bypasses the cache. Bumped to 35 to comfortably exceed 2048 even with tokenizer variance.
        let largeContext = String(repeating: """
        Document context: The user has notes about Swift concurrency, including detailed \
        analysis of actor isolation, async/await patterns, structured concurrency with task groups, \
        and the Sendable protocol for cross-isolation safety. The notes also cover graph theory \
        basics, including vertices and edges, directed vs undirected graphs, and applications to \
        wikilink-based knowledge bases where backlinks make directed links bidirectional. \

        """, count: 35) // ~35 paragraphs → well above 2048 tokens for Sonnet 4.6

        let systemPrompt = """
        You are a personal research assistant for a knowledge base called "Cache Test Vault".
        Cite specific notes when drawing on them using [[Note Title]] format.
        Be concise.

        Knowledge base context:
        \(largeContext)
        """

        let prompts = [
            "What do my notes say about actors?",
            "What do my notes say about task groups?",
            "What do my notes say about graph theory?",
        ]

        var usages: [TokenUsage] = []
        var responses: [String] = []

        for (idx, userPrompt) in prompts.enumerated() {
            let request = LLMRequest(
                userPrompt: userPrompt,
                systemPrompt: systemPrompt,
                streamResponse: false
            )
            let response = try await provider.complete(request)
            usages.append(response.usage ?? TokenUsage(promptTokens: 0, completionTokens: 0))
            responses.append(response.text)
            print("[CACHE] Call \(idx + 1): input=\(response.usage?.promptTokens ?? 0) " +
                  "cache_create=\(response.usage?.cacheCreationInputTokens ?? 0) " +
                  "cache_read=\(response.usage?.cacheReadInputTokens ?? 0) " +
                  "output=\(response.usage?.completionTokens ?? 0)")
        }

        // Save the raw cache data
        struct CacheReport: Codable {
            let prompts: [String]
            let usages: [TokenUsage]
            let responses: [String]
            let timestamp: Date
        }
        let cacheReport = CacheReport(prompts: prompts, usages: usages, responses: responses, timestamp: Date())
        let dir = try Self.resultsDirectory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(ts)-cache-test.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cacheReport).write(to: url)
        print("[CACHE] Wrote cache report to \(url.path)")

        #expect(usages.count == 3, "Should have 3 responses")

        let firstCacheCreate = usages[0].cacheCreationInputTokens
        let firstCacheRead = usages[0].cacheReadInputTokens
        let secondCacheRead = usages[1].cacheReadInputTokens
        let thirdCacheRead = usages[2].cacheReadInputTokens
        print("[CACHE] Call 1: cache_create=\(firstCacheCreate), cache_read=\(firstCacheRead)")
        print("[CACHE] Call 2: cache_read=\(secondCacheRead)")
        print("[CACHE] Call 3: cache_read=\(thirdCacheRead)")

        // HARD assertions: catch regressions in caching
        // (System prompt is >2048 tokens so Sonnet 4.6 should cache it)
        #expect(firstCacheCreate > 0,
                "Call 1 should create cache (cache_control on wrong block, prompt < 2048 tokens, or wrong header)")
        #expect(secondCacheRead > 0,
                "Call 2 should hit cache (system prompt is identical to call 1)")
        #expect(thirdCacheRead > 0,
                "Call 3 should hit cache")

        // Cache hit rate on calls 2-3 should be high (most input tokens come from cache)
        let call2HitRate = Double(secondCacheRead) /
            Double(secondCacheRead + usages[1].cacheCreationInputTokens + usages[1].promptTokens)
        let call3HitRate = Double(thirdCacheRead) /
            Double(thirdCacheRead + usages[2].cacheCreationInputTokens + usages[2].promptTokens)
        print("[CACHE] Call 2 hit rate: \(String(format: "%.1f%%", call2HitRate * 100))")
        print("[CACHE] Call 3 hit rate: \(String(format: "%.1f%%", call3HitRate * 100))")
        #expect(call2HitRate > 0.5, "Call 2 cache hit rate should be > 50%")
        #expect(call3HitRate > 0.5, "Call 3 cache hit rate should be > 50%")
    }

    // MARK: - Live Agent Loop Scenarios

    @Test("Live: simple Q&A scenario")
    func liveSimpleQA() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-simple-qa",
            name: "Live Simple Q&A",
            description: "Real Anthropic call with concurrency vault",
            category: .simpleQA,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: ["concurrency": EvalVaultFixtures.concurrencySearchResults,
                             "actor": EvalVaultFixtures.concurrencySearchResults],
            userPrompt: "What do my notes say about actor reentrancy?",
            currentDocumentID: EvalVaultFixtures.concurrencyDocID,
            scope: .document(EvalVaultFixtures.concurrencyDocID),
            groundTruth: GroundTruth(
                turnRange: 1...3,
                requiredContent: ["reentrancy"],
                minToolCalls: 0
            )
        )

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        let result = try await harness.runLive(scenario: scenario, provider: provider)

        print("[LIVE-QA] Success: \(result.success), turns: \(result.metrics.turnCount), " +
              "tokens: \(result.metrics.totalTokens.totalTokens), " +
              "cache_hit_rate: \(result.metrics.totalTokens.cacheHitRate)")
        print("[LIVE-QA] Output preview: \(result.finalOutput.prefix(200))")
        if !result.failureReasons.isEmpty {
            print("[LIVE-QA] Failures: \(result.failureReasons)")
        }

        let report = EvalReport(promptVariantID: "baseline-v1", results: [result])
        let url = try Self.writeReport(report, suffix: "live-simple-qa")
        print("[LIVE-QA] Report written: \(url.path)")

        #expect(result.metrics.turnCount >= 1)
    }

    @Test("Live: search + synthesize scenario")
    func liveSearchSynthesize() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-search-synthesize",
            name: "Live Search + Synthesize",
            description: "Real agent loop with vault_search + read_document",
            category: .vaultSearchSynthesize,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: [
                "graph": EvalVaultFixtures.graphSearchResults,
                "graph theory": EvalVaultFixtures.graphSearchResults,
            ],
            userPrompt: "Find everything I've written about graph theory and summarize it briefly.",
            groundTruth: GroundTruth(
                turnRange: 2...6,
                requiredContent: ["graph"],
                minToolCalls: 1
            )
        )

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        let result = try await harness.runLive(scenario: scenario, provider: provider)

        print("[LIVE-SS] Success: \(result.success), turns: \(result.metrics.turnCount), " +
              "tools: \(result.metrics.toolCallCount), " +
              "tokens: \(result.metrics.totalTokens.totalTokens), " +
              "cache_hit_rate: \(result.metrics.totalTokens.cacheHitRate)")
        print("[LIVE-SS] Tool calls: \(result.metrics.turns.flatMap { $0.toolCalls.map(\.toolName) })")
        print("[LIVE-SS] Output preview: \(result.finalOutput.prefix(300))")
        if !result.failureReasons.isEmpty {
            print("[LIVE-SS] Failures: \(result.failureReasons)")
        }

        let report = EvalReport(promptVariantID: "baseline-v1", results: [result])
        let url = try Self.writeReport(report, suffix: "live-search-synthesize")
        print("[LIVE-SS] Report written: \(url.path)")

        #expect(result.metrics.turnCount >= 1)
    }

    @Test("Live: empty vault edge case")
    func liveEmptyVault() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-empty-vault",
            name: "Live Empty Vault",
            description: "Agent with empty vault should respond gracefully",
            category: .edgeCaseEmpty,
            vaultDocuments: [],
            userPrompt: "What do my notes say about quantum computing?",
            groundTruth: GroundTruth(
                turnRange: 1...4,
                forbiddenContent: ["error", "crash"]
            )
        )

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        let result = try await harness.runLive(scenario: scenario, provider: provider)

        print("[LIVE-EMPTY] Success: \(result.success), turns: \(result.metrics.turnCount), " +
              "tools: \(result.metrics.toolCallCount), " +
              "tokens: \(result.metrics.totalTokens.totalTokens)")
        print("[LIVE-EMPTY] Output preview: \(result.finalOutput.prefix(200))")
        if !result.failureReasons.isEmpty {
            print("[LIVE-EMPTY] Failures: \(result.failureReasons)")
        }

        let report = EvalReport(promptVariantID: "baseline-v1", results: [result])
        let url = try Self.writeReport(report, suffix: "live-empty-vault")
        print("[LIVE-EMPTY] Report written: \(url.path)")

        #expect(result.metrics.turnCount >= 1)
    }

    // MARK: - Combined Report

    @Test("Live: aggregate report across all scenarios")
    func liveAggregateReport() async throws {
        try Self.requireAPIKey()

        let scenarios: [EvalScenario] = [
            EvalScenario(
                id: "agg-simple-qa", name: "Simple Q&A", description: "",
                category: .simpleQA, vaultDocuments: EvalVaultFixtures.standardVault,
                userPrompt: "Briefly: what is an actor in Swift?",
                currentDocumentID: EvalVaultFixtures.concurrencyDocID,
                scope: .document(EvalVaultFixtures.concurrencyDocID),
                groundTruth: GroundTruth(turnRange: 1...2, requiredContent: ["actor"])
            ),
            EvalScenario(
                id: "agg-search", name: "Search", description: "",
                category: .vaultSearchSynthesize,
                vaultDocuments: EvalVaultFixtures.standardVault,
                queryResultMap: ["sendable": [SearchResult(
                    documentID: EvalVaultFixtures.sendableDocID,
                    title: "Sendable Protocol",
                    excerpt: "The Sendable protocol marks types safe to share across concurrency domains.",
                    score: 0.92
                )]],
                userPrompt: "Search for Sendable and tell me what it does in 2 sentences.",
                groundTruth: GroundTruth(turnRange: 1...4, requiredContent: ["sendable"])
            ),
        ]

        let provider = AnthropicProvider(keychainService: Self.keychain)
        let harness = EvalHarness()
        var results: [ScenarioResult] = []

        for scenario in scenarios {
            let result = try await harness.runLive(scenario: scenario, provider: provider)
            results.append(result)
            print("[AGG] \(scenario.name): success=\(result.success), " +
                  "tokens=\(result.metrics.totalTokens.totalTokens), " +
                  "cache_hit=\(result.metrics.totalTokens.cacheHitRate)")
        }

        let report = EvalReport(promptVariantID: "baseline-v1", results: results)
        let url = try Self.writeReport(report, suffix: "aggregate")
        print("[AGG] Aggregate report: \(url.path)")
        print("[AGG] Task completion rate: \(report.aggregate.taskCompletionRate)")
        print("[AGG] Avg tokens per task: \(report.aggregate.averageTokensPerTask)")
        print("[AGG] Avg cache hit rate: \(report.aggregate.averageCacheHitRate)")
        print("[AGG] Total tokens: \(report.aggregate.totalTokens)")
    }
}

private struct SkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

extension Tag {
    @Tag static var eval: Self
}
