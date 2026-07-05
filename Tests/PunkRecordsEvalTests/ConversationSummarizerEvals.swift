import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// End-to-end evals for the summarize-conversation-to-note flow at the
/// controller seam: a canned summary comes back through the REAL completion
/// machinery (`ScriptedLanguageModel` → `SessionTextCompleter` →
/// `SessionAgentRunner`, the shipping completer path), and the
/// save-through-repository step lands a note on disk with the expected
/// frontmatter, H1, and body.
///
/// This mirrors the deterministic-script approach the other eval suites use, but
/// drives ``ConversationSummarizer`` (no tools, one-shot completion) rather than
/// the agentic `SessionAgentRunner` loop — summarization is a pure
/// text-structuring step, so it rides the `TextCompleter` seam.
@Suite("Conversation Summarizer Evals")
struct ConversationSummarizerEvals {

    private func makeRepo() throws -> (repo: FileSystemDocumentRepository, cleanup: @Sendable () -> Void) {
        let (vault, cleanup) = try TempVaultFactory().createTempVault()
        let repo = FileSystemDocumentRepository(vaultRoot: vault.rootURL, ignoredPaths: [])
        return (repo, cleanup)
    }

    private func makeThread() -> ChatThread {
        var thread = ChatThread()
        thread.update(messages: [
            ChatMessage(role: .user, content: "Should we switch the search index to SQLite FTS5?"),
            ChatMessage(
                role: .assistant,
                content: "Yes — FTS5 gives BM25 ranking and fast prefix search. "
                    + "Decision: adopt FTS5. Open question: how to handle reindex on vault open."
            ),
        ])
        return thread
    }

    @Test("Scripted summary is produced and saved with expected frontmatter/body")
    func summarizeAndSave() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let scriptedSummary = """
        ## Topic
        Whether to adopt SQLite FTS5 for the search index.

        ## Key Points
        - FTS5 provides BM25 ranking and fast prefix search.

        ## Decisions & Outcomes
        - Adopt FTS5 for the search index.

        ## Open Questions
        - How to handle reindexing on vault open.
        """

        // Real completer path, model canned.
        let model = ScriptedLanguageModel(script: [.emitText(scriptedSummary)])
        let summarizer = ConversationSummarizer(
            completer: SessionTextCompleter(model: model),
            repository: repo
        )

        let thread = makeThread()
        let transcript = ThreadTranscriptRenderer.render(
            thread,
            budget: ProviderRegistry.contextBudget(for: .anthropic)
        )
        // The renderer is doing its job: the transcript carries both turns.
        #expect(transcript.contains("FTS5"))

        let body = try await summarizer.summarize(transcript: transcript, threadTitle: thread.title)
        #expect(body.contains("## Decisions & Outcomes"))
        #expect(body.contains("Adopt FTS5"))

        let title = ConversationSummarizer.defaultNoteTitle(forThreadTitle: thread.title)
        let doc = try await summarizer.saveSummaryNote(summaryBody: body, title: title, folder: "")

        // Created document: generated frontmatter + H1 title + body. The H1/title
        // keep the raw title; the path is the sanitized destination (the `?` in the
        // thread title becomes `-`), matching the pure derivation.
        #expect(doc.title == title)
        #expect(doc.path == ConversationSummarizer.destinationPath(inFolder: "", title: title))
        #expect(doc.content.hasPrefix("---"))
        #expect(doc.content.contains("id: \(doc.id.uuidString)"))
        #expect(doc.content.contains("# \(title)"))
        #expect(doc.content.contains("Adopt FTS5"))

        // And it's actually on disk, readable back through the repository.
        let onDisk = try await repo.document(atPath: doc.path)
        #expect(onDisk != nil)
        #expect(onDisk?.content.contains("Adopt FTS5") == true)
    }

    @Test("Saving into a folder lands the note there and reads back")
    func saveIntoFolder() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let summarizer = ConversationSummarizer(
            completer: SessionTextCompleter(model: ScriptedLanguageModel(script: [.emitText("")])),
            repository: repo
        )
        let doc = try await summarizer.saveSummaryNote(
            summaryBody: "## Topic\nFolders.",
            title: "Summary — Folders",
            folder: "Notes"
        )
        #expect(doc.path == "Notes/Summary — Folders.md")
        #expect(try await repo.document(atPath: "Notes/Summary — Folders.md") != nil)
    }

    @Test("Saving twice with the same title uniquifies the filename")
    func uniquifiesOnCollision() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let summarizer = ConversationSummarizer(
            completer: SessionTextCompleter(model: ScriptedLanguageModel(script: [.emitText("")])),
            repository: repo
        )
        let title = "Summary — Chat"
        let first = try await summarizer.saveSummaryNote(summaryBody: "## Topic\nA.", title: title, folder: "")
        let second = try await summarizer.saveSummaryNote(summaryBody: "## Topic\nB.", title: title, folder: "")

        #expect(first.path == "Summary — Chat.md")
        #expect(second.path == "Summary — Chat 2.md")
        #expect(try await repo.document(atPath: first.path) != nil)
        #expect(try await repo.document(atPath: second.path) != nil)
    }

    @Test("A stray frontmatter block in the model output is stripped, leaving one")
    func stripsStrayFrontmatter() async throws {
        let (repo, cleanup) = try makeRepo()
        defer { cleanup() }

        let summarizer = ConversationSummarizer(
            completer: SessionTextCompleter(model: ScriptedLanguageModel(script: [.emitText("")])),
            repository: repo
        )
        let strayBody = """
        ---
        tags: [bogus]
        ---
        ## Topic
        Real content.
        """
        let doc = try await summarizer.saveSummaryNote(
            summaryBody: strayBody,
            title: "Summary — Stray",
            folder: ""
        )
        #expect(!doc.content.contains("bogus"))
        #expect(doc.content.contains("Real content."))
        // Exactly one frontmatter opener (the generated one at the very top).
        #expect(doc.content.hasPrefix("---"))
        let openerCount = doc.content.components(separatedBy: "\n---").count
        // Generated frontmatter contributes one closing "\n---"; the stray block's
        // was stripped, so there should be exactly one.
        #expect(openerCount == 2)
    }
}
