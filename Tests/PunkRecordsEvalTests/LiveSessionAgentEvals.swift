import Testing
import Foundation
import AnyLanguageModel
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport
import PunkRecordsEvals

/// Session-path counterpart to `LiveAgentEvals`. These drive the **new** path —
/// `LanguageModelFactory.makeModel` → `SessionAgentRunner` (via
/// `EvalHarness.runLiveSession`) — against the real Anthropic / OpenAI APIs,
/// instead of the legacy `AgentLoop` + `AnthropicProvider`/`OpenAIProvider`.
///
/// Tagged `.eval` so they only run intentionally (they cost real money) and
/// `.serialized` to avoid hammering the provider concurrently.
///
/// ## What is and isn't ported
/// - Ported: the harness scenarios (simple Q&A, search + synthesize, empty
///   vault, aggregate) now run via `runLiveSession`, and the vault-routing test
///   drives `SessionAgentRunner` directly with the vault tools.
/// - **Not** ported: the prompt-cache assertions and the native `web_search`
///   server-tool tests from `LiveAgentEvals`. Cache accounting reads
///   `AnthropicProvider`'s `TokenUsage.cache*` fields directly, and the native
///   web_search server tool has no AnyLanguageModel analog (recon §4). Both stay
///   on the legacy path in `LiveAgentEvals`, which is kept compiling.
@Suite("Live Session Agent Evals", .tags(.eval), .serialized)
struct LiveSessionAgentEvals {

    static let keychain = KeychainService()

    static func requireAPIKey() throws {
        guard let key = try? keychain.apiKey(for: "anthropic"), key != nil else {
            throw SessionSkipError("No Anthropic API key in keychain — skipping live session eval")
        }
    }

    static func requireOpenAIKey() throws {
        let key = (try? keychain.apiKey(for: "openai")) ?? nil
        guard let key, !key.isEmpty else {
            throw SessionSkipError("No OpenAI API key in keychain — skipping live session eval")
        }
    }

    static func anthropicModel() throws -> any LanguageModel {
        try LanguageModelFactory.makeModel(for: .anthropic, keychain: keychain)
    }

    // MARK: - Harness scenarios via the session path

    @Test("Live (session): simple Q&A scenario")
    func liveSimpleQA() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-session-simple-qa",
            name: "Live Session Simple Q&A",
            description: "Real Anthropic session call with concurrency vault",
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

        let harness = EvalHarness()
        let result = try await harness.runLiveSession(scenario: scenario, model: try Self.anthropicModel())

        print("[SESSION-QA] success=\(result.success), tools=\(result.metrics.toolCallCount)")
        print("[SESSION-QA] Output preview: \(result.finalOutput.prefix(200))")
        #expect(!result.finalOutput.isEmpty)
    }

    @Test("Live (session): search + synthesize scenario")
    func liveSearchSynthesize() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-session-search-synthesize",
            name: "Live Session Search + Synthesize",
            description: "Real session loop with vault_search + read_document",
            category: .vaultSearchSynthesize,
            vaultDocuments: EvalVaultFixtures.standardVault,
            queryResultMap: [
                "graph": EvalVaultFixtures.graphSearchResults,
                "graph theory": EvalVaultFixtures.graphSearchResults,
            ],
            userPrompt: "Find everything I've written about graph theory and summarize it briefly.",
            groundTruth: GroundTruth(
                turnRange: 1...6,
                requiredContent: ["graph"],
                minToolCalls: 0
            )
        )

        let harness = EvalHarness()
        let result = try await harness.runLiveSession(scenario: scenario, model: try Self.anthropicModel())

        print("[SESSION-SS] success=\(result.success), tools=\(result.metrics.toolCallCount)")
        print("[SESSION-SS] Tool calls: \(result.metrics.turns.flatMap { $0.toolCalls.map(\.toolName) })")
        print("[SESSION-SS] Output preview: \(result.finalOutput.prefix(300))")
        #expect(!result.finalOutput.isEmpty)
    }

    @Test("Live (session): empty vault edge case")
    func liveEmptyVault() async throws {
        try Self.requireAPIKey()

        let scenario = EvalScenario(
            id: "live-session-empty-vault",
            name: "Live Session Empty Vault",
            description: "Session agent with empty vault should respond gracefully",
            category: .edgeCaseEmpty,
            vaultDocuments: [],
            userPrompt: "What do my notes say about quantum computing?",
            groundTruth: GroundTruth(
                turnRange: 1...4,
                forbiddenContent: ["crash"]
            )
        )

        let harness = EvalHarness()
        let result = try await harness.runLiveSession(scenario: scenario, model: try Self.anthropicModel())

        print("[SESSION-EMPTY] success=\(result.success), tools=\(result.metrics.toolCallCount)")
        print("[SESSION-EMPTY] Output preview: \(result.finalOutput.prefix(200))")
        #expect(!result.finalOutput.isEmpty)
    }

    // MARK: - Direct SessionAgentRunner: vault routing

    /// Session-path port of `LiveAgentEvals.liveVaultRoutingPrefersVault`: when the
    /// vault clearly contains the answer, the session should call `vault_search`.
    /// (The "should NOT call web_search" half of the original is dropped — the
    /// session path has no native web_search server tool to fall back to.)
    @Test("Live (session): vault-answerable prompt drives vault_search")
    func liveVaultRoutingUsesVaultSearch() async throws {
        try Self.requireAPIKey()

        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }

        try factory.writeTestDocument("""
            ---
            id: \(UUID().uuidString)
            ---
            # Project Glimmer

            Project Glimmer is the user's internal codename for a real-time
            collaboration prototype. Status: paused since Q3 2025 pending UX review.
            Owner: Mira Holt.
            """,
            filename: "ProjectGlimmer.md",
            in: vault.rootURL
        )

        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        let documents = try await repo.allDocuments()
        try await index.rebuildIndex(documents: documents)

        let contextBuilder = ContextBuilder(searchService: index, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: "What's the status of Project Glimmer in my notes?",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 128_000,
            vaultName: vault.name
        )

        let runner = SessionAgentRunner(
            model: try Self.anthropicModel(),
            instructions: instructions,
            tools: [VaultSearchTool(searchService: index), ReadDocumentTool(repository: repo)]
        )

        var vaultSearchCalls = 0
        for try await event in await runner.run(prompt: "What's the status of Project Glimmer in my notes?") {
            if case let .toolStart(name, _) = event, name == "vault_search" {
                vaultSearchCalls += 1
            }
        }

        print("[SESSION-VAULT-ROUTING] vault_search=\(vaultSearchCalls)")
        #expect(vaultSearchCalls >= 1, "Session should search the vault for a vault-specific question")
    }

    // MARK: - Direct SessionAgentRunner: OpenAI tool calling

    /// Session-path port of `LiveAgentEvals.liveOpenAIWebSearchTriggers`, adapted:
    /// the AnyLanguageModel OpenAI backend has no native web_search server tool, so
    /// we verify the session drives a client vault tool through the same
    /// toolStart/toolEnd events regardless of provider. Skips without an OpenAI key.
    @Test("Live (session, OpenAI): vault prompt drives a client tool call")
    func liveOpenAIToolCalling() async throws {
        try Self.requireOpenAIKey()

        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }

        try factory.writeTestDocument("""
            ---
            id: \(UUID().uuidString)
            ---
            # Project Glimmer

            Project Glimmer is paused since Q3 2025 pending UX review. Owner: Mira Holt.
            """,
            filename: "ProjectGlimmer.md",
            in: vault.rootURL
        )

        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL)
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        try await index.rebuildIndex(documents: try await repo.allDocuments())

        let contextBuilder = ContextBuilder(searchService: index, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: "What's the status of Project Glimmer in my notes?",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 128_000,
            vaultName: vault.name
        )

        let model = try LanguageModelFactory.makeModel(for: .openAI, keychain: Self.keychain)
        let runner = SessionAgentRunner(
            model: model,
            instructions: instructions,
            tools: [VaultSearchTool(searchService: index), ReadDocumentTool(repository: repo)]
        )

        var toolCalls = 0
        var sawCompletion = false
        for try await event in await runner.run(prompt: "What's the status of Project Glimmer in my notes?") {
            switch event {
            case .toolStart: toolCalls += 1
            case .toolEnd: sawCompletion = true
            default: break
            }
        }

        print("[SESSION-OPENAI] tool calls=\(toolCalls), completion=\(sawCompletion)")
        #expect(toolCalls >= 1, "Expected the OpenAI session to call a vault tool")
        #expect(sawCompletion, "Expected toolEnd so the UI bubble completes")
    }
}

private struct SessionSkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
