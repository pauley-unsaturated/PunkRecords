import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals
@testable import PunkRecordsInfra
import PunkRecordsTestSupport

/// Regression evals for the session path's context threading — the riskiest
/// correctness area of the FoundationModels rehoming.
///
/// `SessionAgentRunner` deliberately passes the session NO instructions and
/// re-folds everything (system prompt + vault excerpts + accumulated tool
/// results) into each round's prompt, because AnyLanguageModel backends may be
/// stateless (Ollama sends only the latest prompt). Nothing else guards that
/// behavior end-to-end, so these evals spy on the exact prompt text the model
/// receives each round via ``ScriptedLanguageModel/PromptLog``.
@Suite("Session context threading evals")
struct SessionContextThreadingEvals {

    /// Distinctive markers that must survive the pipeline verbatim.
    static let docMarker = "REENTRANCY-MARKER-XYZ"
    static let toolMarker = "TOOL-OUTPUT-MARKER-ABC"

    /// Seed a one-document vault whose content carries ``docMarker``.
    private func makeVault() async throws -> (MockDocumentRepository, MockSearchService, Document) {
        let repo = MockDocumentRepository()
        let search = MockSearchService()
        let doc = Document(
            title: "Actor Reentrancy Notes",
            content: """
            # Actor Reentrancy Notes

            Re-check preconditions after suspension points. \(Self.docMarker)
            """,
            path: "swift/actor-reentrancy-notes.md",
            tags: ["swift"]
        )
        try await repo.save(doc)
        await search.setQueryResults(["glimmer": [
            SearchResult(
                documentID: doc.id,
                title: "Project Glimmer Status",
                excerpt: Self.toolMarker,
                score: 0.9
            ),
        ]])
        return (repo, search, doc)
    }

    /// Build instructions exactly the way the chat panel does for a given
    /// context budget, then run one scripted turn and return the round prompts.
    private func roundPrompts(
        maxTokens: Int,
        script: [ScriptedLanguageModel.Step],
        userPrompt: String = "What do my notes say about reentrancy?"
    ) async throws -> (prompts: [String], instructions: String) {
        let (repo, search, doc) = try await makeVault()
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: userPrompt,
            scope: .document(doc.id),
            currentDocumentID: doc.id,
            maxTokens: maxTokens,
            vaultName: "Threading Vault"
        )

        let log = ScriptedLanguageModel.PromptLog()
        let model = ScriptedLanguageModel(script: script, promptLog: log)
        let runner = SessionAgentRunner(
            model: model,
            instructions: instructions,
            tools: [VaultSearchTool(searchService: search)]
        )
        for try await _ in await runner.run(prompt: userPrompt) { }
        return (log.prompts, instructions)
    }

    // MARK: - Instruction folding, per context tier

    @Test("Round 1 prompt carries instructions + vault excerpt + user request, at every tier",
          arguments: [3_000, 8_000, 128_000])
    func instructionsFoldedIntoFirstRound(maxTokens: Int) async throws {
        let (prompts, instructions) = try await roundPrompts(
            maxTokens: maxTokens,
            script: [.emitText("Answered.")]
        )

        try #require(prompts.count == 1)
        let first = prompts[0]
        #expect(first.contains(Self.docMarker),
                "tier(\(maxTokens)) round-1 prompt must carry the vault excerpt")
        #expect(first.contains("User request:"),
                "round prompt must restate the user request block")
        #expect(first.contains("What do my notes say about reentrancy?"))
        // The whole assembled instruction block is folded in, not a summary.
        #expect(first.contains(instructions),
                "buildInstructions output must appear verbatim in the round prompt")
    }

    // MARK: - Tool-result threading

    @Test("After a tool round, the next round's prompt folds in the tool output AND restates instructions")
    func toolResultsThreadIntoNextRound() async throws {
        let (prompts, instructions) = try await roundPrompts(
            maxTokens: 128_000,
            script: [
                .callTool(name: "vault_search", arguments: ["query": .string("glimmer")]),
                .endTurn,
                .emitText("Based on the tool results, done."),
            ]
        )

        try #require(prompts.count == 2)
        let second = prompts[1]
        #expect(second.contains("Results from tools you have already called this turn"),
                "round 2 must announce prior tool results")
        #expect(second.contains(Self.toolMarker),
                "the vault_search output must be folded into round 2's prompt")
        #expect(second.contains(instructions),
                "instructions must be restated every round (stateless backends)")
        // Round 1 must NOT already claim tool results exist.
        #expect(!prompts[0].contains("Results from tools"),
                "round 1 has no tool results yet")
    }

    // MARK: - Round cap / force-answer

    @Test("An exhausted script burns to the round cap and the final round forbids more tools")
    func forceAnswerOnFinalRound() async throws {
        // Empty script: every round returns no text, so the runner loops to
        // its cap and the last round must carry the force-answer directive.
        let (prompts, _) = try await roundPrompts(maxTokens: 8_000, script: [])

        #expect(prompts.count == SessionAgentRunner.maxToolRounds)
        #expect(prompts.last?.contains("Do NOT call any tools") == true,
                "final allowed round must force a tool-free answer")
        #expect(prompts.dropLast().allSatisfy { !$0.contains("Do NOT call any tools") },
                "earlier rounds must not prematurely forbid tools")
    }
}
