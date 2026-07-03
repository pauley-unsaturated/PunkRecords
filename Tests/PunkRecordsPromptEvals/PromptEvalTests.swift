import Testing
import Foundation
import AnyLanguageModel
@testable import PunkRecordsCore
@testable import PunkRecordsInfra
import PunkRecordsTestSupport

/// End-to-end prompt evaluations against the real Anthropic API, on the
/// **session path** the app ships (`LanguageModelFactory` →
/// `SessionTextCompleter` / `NoteCompiler`), not the deleted legacy
/// orchestrator.
///
/// These tests validate that our prompts produce structurally correct output:
/// frontmatter, headings, wikilinks, tags, and coherent content.
///
/// They require an Anthropic API key in the macOS Keychain
/// (service: "com.markpauley.PunkRecords", key: "api-key-anthropic").
///
/// These cost real API credits — run intentionally, not on every build.
@Suite("Prompt Evals", .tags(.eval))
struct PromptEvalTests {

    // MARK: - Fixtures

    static let keychain = KeychainService()

    /// Sample documents representing a realistic vault for context building.
    static let vaultDocuments: [Document] = [
        Document(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            title: "Swift Concurrency Deep Dive",
            content: """
            # Swift Concurrency Deep Dive

            Swift's concurrency model is built on **structured concurrency** and the `async/await` pattern.

            ## Actors

            Actors provide *data-race safety* by isolating their mutable state. Only one task can execute
            on an actor at a time.

            ## Task Groups

            Use `withTaskGroup` when you need to fan out work and collect results.

            See also [[Actor Reentrancy]] and [[Sendable Protocol]].
            """,
            path: "swift/concurrency-deep-dive.md",
            tags: ["swift", "concurrency", "async-await"],
            linkedDocumentIDs: [UUID(uuidString: "33333333-3333-3333-3333-333333333333")!]
        ),
        Document(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "Actor Reentrancy",
            content: """
            # Actor Reentrancy

            Actor reentrancy is a subtle issue in Swift concurrency. When an actor method hits a suspension
            point (`await`), other callers can execute on the actor in the meantime.

            See [[Swift Concurrency Deep Dive]] for the broader concurrency model.
            """,
            path: "swift/actor-reentrancy.md",
            tags: ["swift", "concurrency"]
        ),
        Document(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Graph Theory Basics",
            content: """
            # Graph Theory Basics

            A graph G = (V, E) consists of vertices and edges.

            ## Directed vs Undirected

            Wikilinks in a knowledge base are directed but we compute backlinks to make them bidirectional.

            See [[Swift Concurrency Deep Dive]] for practical applications.
            """,
            path: "math/graph-theory-basics.md",
            tags: ["math", "graph-theory"]
        ),
    ]

    /// Seed a mock vault and return its repo/search pair.
    static func makeVault() async throws -> (MockDocumentRepository, MockSearchService) {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()
        for doc in vaultDocuments {
            try await mockRepo.save(doc)
        }
        return (mockRepo, mockSearch)
    }

    /// The real Anthropic model via the same factory the app uses.
    static func anthropicModel() throws -> any LanguageModel {
        try LanguageModelFactory.makeModel(for: .anthropic, keychain: keychain)
    }

    /// Run one instructed chat completion the way the app does: assemble
    /// instructions with `ContextBuilder.buildInstructions`, then drive the
    /// session path via `SessionTextCompleter`.
    static func completeChat(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        repo: MockDocumentRepository,
        search: MockSearchService
    ) async throws -> String {
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let instructions = try await contextBuilder.buildInstructions(
            prompt: prompt,
            scope: scope,
            currentDocumentID: currentDocumentID,
            maxTokens: 128_000,
            vaultName: "Eval Vault"
        )
        let completer = SessionTextCompleter(model: try anthropicModel(), instructions: instructions)
        return try await completer.complete(prompt: prompt)
    }

    /// Skip the test if no API key is available.
    static func requireAPIKey() throws {
        guard let key = try? keychain.apiKey(for: "anthropic"), key != nil else {
            throw SkipError("No Anthropic API key in keychain — skipping eval")
        }
    }

    // MARK: - Context Builder System Prompt

    @Test("System prompt has correct structure")
    func systemPromptStructure() async throws {
        let mockRepo = MockDocumentRepository()
        let mockSearch = MockSearchService()
        let contextBuilder = ContextBuilder(searchService: mockSearch, repository: mockRepo)

        // Seed a document
        let doc = Self.vaultDocuments[0]
        try await mockRepo.save(doc)

        let (systemPrompt, excerpts) = try await contextBuilder.buildContext(
            prompt: "Tell me about concurrency",
            scope: .document(doc.id),
            currentDocumentID: doc.id,
            maxTokens: 8000,
            vaultName: "Test Vault"
        )

        // Structural checks on the system prompt
        #expect(systemPrompt.contains("Test Vault"), "System prompt should mention vault name")
        #expect(systemPrompt.contains("research assistant"), "System prompt should define the role")
        #expect(systemPrompt.contains("[["), "System prompt should contain wikilink citations")
        #expect(!excerpts.isEmpty, "Should have context excerpts")

        // Check that excerpt titles appear in the system prompt
        for excerpt in excerpts {
            #expect(
                systemPrompt.contains(excerpt.title),
                "System prompt should include excerpt title: \(excerpt.title)"
            )
        }
    }

    // MARK: - KB Query (Chat)

    @Test("KB query returns relevant, grounded response", .tags(.eval))
    func kbQueryEval() async throws {
        try Self.requireAPIKey()

        let (mockRepo, mockSearch) = try await Self.makeVault()

        // Set up search results so context builder finds docs
        await mockSearch.setSearchResults([
            SearchResult(
                documentID: Self.vaultDocuments[0].id,
                title: "Swift Concurrency Deep Dive",
                excerpt: "Swift's concurrency model is built on structured concurrency and the async/await pattern.",
                score: 0.95,
                matchRanges: []
            )
        ])

        let text = try await Self.completeChat(
            prompt: "What do my notes say about actor reentrancy?",
            scope: .global,
            currentDocumentID: Self.vaultDocuments[0].id,
            repo: mockRepo,
            search: mockSearch
        )

        // Structural assertions
        MarkdownAssertions.hasMinimumLength(text, minWords: 20)

        // Content should reference concepts from the vault
        let mentionsConcurrency = text.lowercased().contains("actor") ||
                                  text.lowercased().contains("reentrancy") ||
                                  text.lowercased().contains("concurrency")
        #expect(mentionsConcurrency, "Response should mention actor/reentrancy/concurrency concepts")

        // Token usage assertions were dropped with the legacy provider: the
        // session path reports no usage yet (PUNK-4bu tracks restoring it).
    }

    // MARK: - Save Response As Note

    @Test("saveResponseAsNote produces well-structured wiki article", .tags(.eval))
    func saveAsNoteEval() async throws {
        try Self.requireAPIKey()

        let (mockRepo, _) = try await Self.makeVault()
        // Same wiring as production: NoteCompiler over the session-path completer.
        let compiler = NoteCompiler(
            completer: SessionTextCompleter(model: try Self.anthropicModel()),
            repository: mockRepo
        )

        let chatResponse = """
        Swift's actor model provides data-race safety through isolation. Each actor has its own
        serial executor, meaning only one task can run on it at a time. However, actor reentrancy
        is a subtle issue: when you hit an `await` inside an actor method, other callers can
        interleave. The fix is to re-check state after every suspension point.

        Key patterns:
        - Use actors for mutable shared state
        - Always re-check preconditions after await
        - Consider using `withCheckedContinuation` for bridging callback APIs
        - Task groups provide structured fan-out

        This relates to both the Sendable protocol (for cross-isolation safety) and
        Swift's broader structured concurrency model.
        """

        let doc = try await compiler.saveResponseAsNote(
            responseText: chatResponse,
            sourceDocumentID: Self.vaultDocuments[0].id,
            folderPath: "compiled"
        )

        let content = doc.content

        // Structural checks on the generated note
        MarkdownAssertions.hasH1(content)
        MarkdownAssertions.hasFrontmatter(content)
        MarkdownAssertions.hasTags(content, minCount: 1)
        MarkdownAssertions.hasWikilinks(content, minCount: 1)
        MarkdownAssertions.hasMinimumLength(content, minWords: 30)
        MarkdownAssertions.noMetaCommentary(content)
        MarkdownAssertions.parsesSuccessfully(content)

        // The saved document should have a real path
        #expect(doc.path.hasSuffix(".md"), "Document path should end with .md")
        #expect(doc.path.hasPrefix("compiled/"), "Document should be saved in the requested folder")

        // Should have tags
        #expect(!doc.tags.isEmpty, "Document should have tags")
    }

    // MARK: - Compile From Source

    @Test("compileFromSource produces structured wiki from raw material", .tags(.eval))
    func compileFromSourceEval() async throws {
        try Self.requireAPIKey()

        let (mockRepo, _) = try await Self.makeVault()
        let compiler = NoteCompiler(
            completer: SessionTextCompleter(model: try Self.anthropicModel()),
            repository: mockRepo
        )

        let sourceContent = """
        Meeting notes — 2026-03-20, Architecture Review

        Attendees: Mark, Sarah, Raj

        We discussed migrating from GCD to Swift Concurrency across the codebase.
        Key decisions:
        - All new code must use async/await, no new DispatchQueue usage
        - Existing actors should be audited for reentrancy issues (Raj will own this)
        - The networking layer will be migrated first as a pilot
        - We'll use TaskGroup for the batch image processing pipeline
        - Sendable conformance to be enforced via strict concurrency checking (-strict-concurrency=complete)
        - Target: complete migration by end of Q2

        Open questions:
        - Should we wrap legacy completion handlers with withCheckedContinuation or withUnsafeContinuation?
        - How to handle the SQLite layer which currently uses a serial DispatchQueue for isolation?

        Action items:
        - Raj: audit actor reentrancy in BankAccount and ImageLoader actors
        - Sarah: prototype networking layer migration
        - Mark: enable strict concurrency in CI and triage warnings
        """

        let doc = try await compiler.compileFromSource(
            sourceContent: sourceContent,
            sourceTitle: "Architecture Review Meeting Notes",
            folderPath: ""
        )

        let content = doc.content

        // Structural checks
        MarkdownAssertions.hasH1(content)
        MarkdownAssertions.hasFrontmatter(content)
        MarkdownAssertions.hasTags(content, minCount: 1)
        MarkdownAssertions.hasWikilinks(content, minCount: 1)
        MarkdownAssertions.hasSections(content, minCount: 2)
        MarkdownAssertions.hasMinimumLength(content, minWords: 50)
        MarkdownAssertions.noMetaCommentary(content)
        MarkdownAssertions.parsesSuccessfully(content)

        // Content checks — the compiled article should extract key knowledge
        let text = content.lowercased()
        let mentionsConcurrency = text.contains("async") || text.contains("concurrency") || text.contains("actor")
        #expect(mentionsConcurrency, "Compiled note should mention concurrency concepts from the source")

        // Should not just be a verbatim copy
        #expect(!content.contains("Attendees: Mark, Sarah, Raj"),
                "Compiled note should restructure, not copy verbatim")
    }

    // MARK: - Prompt Regression: System Prompt Doesn't Leak

    @Test("LLM response doesn't echo back the system prompt")
    func noSystemPromptLeakage() async throws {
        try Self.requireAPIKey()

        let (mockRepo, mockSearch) = try await Self.makeVault()

        let text = (try await Self.completeChat(
            prompt: "What is 2 + 2?",
            scope: .global,
            currentDocumentID: nil,
            repo: mockRepo,
            search: mockSearch
        )).lowercased()

        // The response should not contain fragments of our system prompt
        #expect(!text.contains("knowledge base context:"), "Response leaked system prompt")
        #expect(!text.contains("you are a personal research assistant"), "Response leaked system prompt role")
    }
}

// MARK: - Tags

extension Tag {
    @Tag static var eval: Self
}

// MARK: - Skip support

private struct SkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
