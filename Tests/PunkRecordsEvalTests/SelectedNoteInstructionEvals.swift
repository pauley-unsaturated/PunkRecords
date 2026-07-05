import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsEvals
@testable import PunkRecordsInfra
import PunkRecordsTestSupport

/// Deterministic evals that the session path EXPLICITLY NAMES the selected note
/// in the instructions the model receives (round 0), and only for a note-focused
/// scope.
///
/// The note's *content* has always been folded into the prompt; these guard the
/// additive naming line `ContextBuilder.buildInstructions` emits so the model can
/// resolve deixis ("this note", "it"). Like `SessionContextThreadingEvals`, this
/// spies on the exact round prompt via ``ScriptedLanguageModel/PromptLog`` and
/// drives the REAL `SessionAgentRunner` — no network, no API key.
@Suite("Selected-note instruction evals")
struct SelectedNoteInstructionEvals {

    static let noteTitle = "Actor Reentrancy Notes"
    static let notePath = "swift/actor-reentrancy-notes.md"

    /// Phrase that appears ONLY in the selected-note naming fragment — never in
    /// the excerpt rendering (which uses `--- [[Title]] ---`), so its presence
    /// unambiguously means the note was NAMED.
    static let namingPhrase = "refers to it unless stated otherwise"
    static func titlePhrase() -> String { "titled \"\(noteTitle)\"" }

    private func makeVault() async throws -> (MockDocumentRepository, MockSearchService, Document) {
        let repo = MockDocumentRepository()
        let search = MockSearchService()
        let doc = Document(
            title: Self.noteTitle,
            content: "# \(Self.noteTitle)\n\nRe-check preconditions after suspension points.",
            path: Self.notePath,
            tags: ["swift"]
        )
        try await repo.save(doc)
        return (repo, search, doc)
    }

    /// Build instructions for `makeScope(doc)` the way the chat panel does, run one
    /// scripted round, and return that round's prompt. Uses a SINGLE seeded doc so
    /// the scope's id always resolves against the repository.
    private func roundZeroPrompt(
        makeScope: (Document) -> QueryScope,
        currentDocumentID: (Document) -> DocumentID?
    ) async throws -> String {
        let (repo, search, doc) = try await makeVault()
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: "What does this note say about reentrancy?",
            scope: makeScope(doc),
            currentDocumentID: currentDocumentID(doc),
            maxTokens: 8_000,
            vaultName: "Threading Vault"
        )

        let log = ScriptedLanguageModel.PromptLog()
        let model = ScriptedLanguageModel(script: [.emitText("Answered.")], promptLog: log)
        let runner = SessionAgentRunner(
            model: model,
            instructions: instructions,
            tools: [VaultSearchTool(searchService: search)]
        )
        for try await _ in await runner.run(prompt: "What does this note say about reentrancy?") { }
        let prompts = log.prompts
        try #require(prompts.count == 1)
        return prompts[0]
    }

    @Test("Round-0 prompt NAMES the selected note under document scope")
    func documentScopeNamesNote() async throws {
        let prompt = try await roundZeroPrompt(
            makeScope: { .document($0.id) },
            currentDocumentID: { $0.id }
        )

        #expect(prompt.contains(Self.titlePhrase()),
                "document-scope round-0 prompt must name the selected note by title")
        #expect(prompt.contains(Self.notePath),
                "the note's path must appear so the naming is unambiguous")
        #expect(prompt.contains(Self.namingPhrase),
                "the naming fragment must be folded into the round-0 prompt")
    }

    @Test("Round-0 prompt does NOT name a note under vault-wide (global) scope")
    func globalScopeOmitsNote() async throws {
        // A document is open (currentDocumentID set) so its content is still
        // included, but a vault-wide scope must suppress the naming line.
        let prompt = try await roundZeroPrompt(
            makeScope: { _ in .global },
            currentDocumentID: { $0.id }
        )

        #expect(!prompt.contains(Self.namingPhrase),
                "vault-wide scope must not tell the model the conversation refers to one note")
        #expect(!prompt.contains(Self.titlePhrase()),
                "vault-wide scope must not name a selected note")
        // Sanity: the note content is still present (naming is additive, not a gate
        // on inclusion) — proves the absence above isn't just an empty prompt.
        #expect(prompt.contains("[[\(Self.noteTitle)]]"),
                "the current document's excerpt is still folded in under global scope")
    }
}
