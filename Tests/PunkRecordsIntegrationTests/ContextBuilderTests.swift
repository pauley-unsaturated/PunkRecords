import Testing
@testable import PunkRecordsCore
import PunkRecordsTestSupport

@Suite("ContextBuilder Tests")
struct ContextBuilderTests {

    // MARK: - Helpers

    private func makeDocument(
        id: DocumentID = DocumentID(),
        title: String = "Test Note",
        content: String = "Some test content for the document.",
        path: String = "notes/test.md",
        linkedDocumentIDs: [DocumentID] = []
    ) -> Document {
        Document(
            id: id,
            title: title,
            content: content,
            path: path,
            linkedDocumentIDs: linkedDocumentIDs
        )
    }

    private func makeSearchResult(
        documentID: DocumentID,
        title: String = "Search Hit",
        excerpt: String = "Matching excerpt content.",
        score: Float = 0.8
    ) -> SearchResult {
        SearchResult(
            documentID: documentID,
            title: title,
            excerpt: excerpt,
            score: score
        )
    }

    // MARK: - ContextTier

    @Test("ContextTier classifies small budget correctly")
    func tierSmall() {
        #expect(ContextBuilder.ContextTier(maxTokens: 0) == .small)
        #expect(ContextBuilder.ContextTier(maxTokens: 2000) == .small)
        #expect(ContextBuilder.ContextTier(maxTokens: 3999) == .small)
    }

    @Test("ContextTier classifies medium budget correctly")
    func tierMedium() {
        #expect(ContextBuilder.ContextTier(maxTokens: 4000) == .medium)
        #expect(ContextBuilder.ContextTier(maxTokens: 16000) == .medium)
        #expect(ContextBuilder.ContextTier(maxTokens: 31999) == .medium)
    }

    @Test("ContextTier classifies large budget correctly")
    func tierLarge() {
        #expect(ContextBuilder.ContextTier(maxTokens: 32000) == .large)
        #expect(ContextBuilder.ContextTier(maxTokens: 128000) == .large)
    }

    // MARK: - Small Context (< 4k tokens)

    @Test("Small budget includes only current document")
    func smallBudgetCurrentDocOnly() async throws {
        let doc = makeDocument(content: "Short note content.")
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        // Set up search results that should NOT appear in small context
        let otherID = DocumentID()
        await searchService.setSearchResults([
            makeSearchResult(documentID: otherID, title: "Other Note")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "test",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 2000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.count == 1)
        #expect(result.excerpts[0].documentID == doc.id)
        #expect(result.excerpts[0].title == "Test Note")
    }

    @Test("Small budget with nil current document returns empty excerpts")
    func smallBudgetNilDocument() async throws {
        let searchService = MockSearchService()
        let repository = MockDocumentRepository()

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "test",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 2000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.isEmpty)
    }

    @Test("Small budget with non-existent document ID returns empty excerpts")
    func smallBudgetMissingDocument() async throws {
        let searchService = MockSearchService()
        let repository = MockDocumentRepository()

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "test",
            scope: .global,
            currentDocumentID: DocumentID(),
            maxTokens: 2000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.isEmpty)
    }

    // MARK: - Medium Context (4k-32k tokens)

    @Test("Medium budget includes current doc and search results")
    func mediumBudgetIncludesSearchResults() async throws {
        let doc = makeDocument(content: "Current document content.")
        let searchID = DocumentID()
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        await searchService.setSearchResults([
            makeSearchResult(documentID: searchID, title: "Related Note", excerpt: "Related content here.")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "some query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 8000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.count == 2)
        #expect(result.excerpts[0].documentID == doc.id)
        #expect(result.excerpts[1].documentID == searchID)
    }

    @Test("Medium budget deduplicates current doc appearing in search results")
    func mediumBudgetDeduplicates() async throws {
        let doc = makeDocument(content: "Current document content.")
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        // Search returns the same document that is the current doc
        await searchService.setSearchResults([
            makeSearchResult(documentID: doc.id, title: "Test Note", excerpt: "Current document content.")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 8000,
            vaultName: "TestVault"
        )

        // Should not contain duplicates
        let ids = result.excerpts.map(\.documentID)
        #expect(Set(ids).count == ids.count)
        #expect(result.excerpts.count == 1)
    }

    @Test("Medium budget with nil current doc still includes search results")
    func mediumBudgetNilDocStillSearches() async throws {
        let searchID = DocumentID()
        let searchService = MockSearchService()
        let repository = MockDocumentRepository()

        await searchService.setSearchResults([
            makeSearchResult(documentID: searchID, title: "Found Note", excerpt: "Found content.")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 8000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.count == 1)
        #expect(result.excerpts[0].documentID == searchID)
    }

    // MARK: - Large Context (32k+ tokens)

    @Test("Large budget includes graph neighbors")
    func largeBudgetIncludesGraphNeighbors() async throws {
        let linkedID = DocumentID()
        let linkedDoc = makeDocument(id: linkedID, title: "Linked Note", content: "Linked content.", path: "notes/linked.md")
        let doc = makeDocument(content: "Main document.", linkedDocumentIDs: [linkedID])

        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc, linkedDoc])

        await searchService.setSearchResults([])
        await searchService.setBacklinkMap([:])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 64000,
            vaultName: "TestVault"
        )

        let ids = Set(result.excerpts.map(\.documentID))
        #expect(ids.contains(doc.id))
        #expect(ids.contains(linkedID))
    }

    @Test("Large budget includes backlinks")
    func largeBudgetIncludesBacklinks() async throws {
        let backlinkID = DocumentID()
        let backlinkDoc = makeDocument(id: backlinkID, title: "Backlinker", content: "References main doc.", path: "notes/backlinker.md")
        let doc = makeDocument(content: "Main document.")

        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc, backlinkDoc])

        await searchService.setSearchResults([])
        await searchService.setBacklinkMap([doc.id: [backlinkID]])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 64000,
            vaultName: "TestVault"
        )

        let ids = Set(result.excerpts.map(\.documentID))
        #expect(ids.contains(doc.id))
        #expect(ids.contains(backlinkID))
    }

    @Test("Large budget deduplicates candidates keeping highest score")
    func largeBudgetDeduplicatesByScore() async throws {
        let sharedID = DocumentID()
        let sharedDoc = makeDocument(
            id: sharedID,
            title: "Shared Note",
            content: "Shared content.",
            path: "notes/shared.md"
        )
        let doc = makeDocument(content: "Main document.", linkedDocumentIDs: [sharedID])

        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc, sharedDoc])

        // The shared doc appears in both search results AND as a graph neighbor
        await searchService.setSearchResults([
            makeSearchResult(documentID: sharedID, title: "Shared Note", excerpt: "Shared content.", score: 0.5)
        ])
        await searchService.setBacklinkMap([:])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 64000,
            vaultName: "TestVault"
        )

        // Shared doc should appear only once
        let sharedExcerpts = result.excerpts.filter { $0.documentID == sharedID }
        #expect(sharedExcerpts.count == 1)

        // Its score should reflect the graph bonus (higher than raw search score of 0.5)
        #expect(sharedExcerpts[0].relevanceScore > 0.5)
    }

    @Test("Large budget with nil current doc uses only search results")
    func largeBudgetNilDoc() async throws {
        let searchID = DocumentID()
        let searchService = MockSearchService()
        let repository = MockDocumentRepository()

        await searchService.setSearchResults([
            makeSearchResult(documentID: searchID, title: "Result", excerpt: "Content.")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "query",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 64000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.count == 1)
        #expect(result.excerpts[0].documentID == searchID)
    }

    // MARK: - System Prompt

    @Test("System prompt includes vault name")
    func systemPromptIncludesVaultName() async throws {
        let searchService = MockSearchService()
        let repository = MockDocumentRepository()

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "test",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 2000,
            vaultName: "My Research Vault"
        )

        #expect(result.systemPrompt.contains("My Research Vault"))
    }

    @Test("System prompt includes excerpt titles in wiki-link format")
    func systemPromptIncludesExcerptTitles() async throws {
        let doc = makeDocument(title: "Important Note", content: "Key information here.")
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "test",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 2000,
            vaultName: "TestVault"
        )

        #expect(result.systemPrompt.contains("[[Important Note]]"))
    }

    // MARK: - Edge Cases

    @Test("Zero token budget returns empty excerpts and system prompt")
    func zeroBudgetReturnsEmpty() async throws {
        let doc = makeDocument(content: "Content.")
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        // A very long prompt with tiny maxTokens leaves no context budget
        let longPrompt = String(repeating: "word ", count: 5000)
        let result = try await builder.buildContext(
            prompt: longPrompt,
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 1000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.isEmpty)
    }

    @Test("Current document gets relevance score of 1.0 in small tier")
    func currentDocRelevanceScore() async throws {
        let doc = makeDocument(content: "Content.")
        let searchService = MockSearchService()
        let repository = MockDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let result = try await builder.buildContext(
            prompt: "q",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 2000,
            vaultName: "TestVault"
        )

        #expect(result.excerpts.count == 1)
        #expect(result.excerpts[0].relevanceScore == 1.0)
    }
}
