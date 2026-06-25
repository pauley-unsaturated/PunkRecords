import Foundation
import Testing
@testable import PunkRecordsCore

// MARK: - Local mocks
//
// The Core test target only depends on `PunkRecordsCore`; it cannot depend on
// `PunkRecordsTestSupport` (which itself depends on Core, which would form a
// dependency cycle). So these minimal in-memory mocks mirror the TestSupport
// `MockSearchService` / `MockDocumentRepository` used by the integration tests.

private actor StubSearchService: SearchService {
    var searchResults: [SearchResult] = []
    var backlinkMap: [DocumentID: [DocumentID]] = [:]

    func search(query: String) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        return searchResults
    }

    func index(document: Document) async throws {}
    func removeFromIndex(documentID: DocumentID) async throws {}
    func rebuildIndex(documents: [Document]) async throws {}

    func backlinks(for documentID: DocumentID) async throws -> [DocumentID] {
        backlinkMap[documentID] ?? []
    }

    func setSearchResults(_ results: [SearchResult]) { searchResults = results }
    func setBacklinkMap(_ map: [DocumentID: [DocumentID]]) { backlinkMap = map }
}

private actor StubDocumentRepository: DocumentRepository {
    var documents: [DocumentID: Document] = [:]
    private let changesContinuation: AsyncStream<VaultChange>.Continuation
    let changes: AsyncStream<VaultChange>

    init(documents: [Document] = []) {
        let (stream, continuation) = AsyncStream<VaultChange>.makeStream()
        self.changes = stream
        self.changesContinuation = continuation
        for doc in documents { self.documents[doc.id] = doc }
    }

    func document(withID id: DocumentID) async throws -> Document? { documents[id] }
    func document(atPath path: RelativePath) async throws -> Document? {
        documents.values.first { $0.path == path }
    }
    func allDocuments() async throws -> [Document] { Array(documents.values) }
    func documentsInFolder(_ path: RelativePath) async throws -> [Document] {
        documents.values.filter { $0.path.hasPrefix(path) }
    }
    func save(_ document: Document) async throws {
        documents[document.id] = document
        changesContinuation.yield(.added(document))
    }
    func delete(_ document: Document) async throws {
        documents.removeValue(forKey: document.id)
        changesContinuation.yield(.deleted(document.id, path: document.path))
    }
    func move(_ document: Document, to newPath: RelativePath) async throws {}
}

@Suite("ContextBuilder buildInstructions Tests")
struct ContextBuilderInstructionsTests {

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
        SearchResult(documentID: documentID, title: title, excerpt: excerpt, score: score)
    }

    // MARK: - System prompt presence

    @Test("Instructions include the system prompt header and vault name")
    func instructionsIncludeSystemPrompt() async throws {
        let searchService = StubSearchService()
        let repository = StubDocumentRepository()

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let instructions = try await builder.buildInstructions(
            prompt: "test",
            scope: .global,
            currentDocumentID: nil,
            maxTokens: 2000,
            vaultName: "My Research Vault"
        )

        // System-prompt header content is present.
        #expect(instructions.contains("My Research Vault"))
        #expect(instructions.contains("vault_search"))
        #expect(instructions.contains("web_search"))
        #expect(instructions.contains("[[Note Title]]"))
        #expect(instructions.contains("Knowledge base context:"))
    }

    // MARK: - Excerpt content rendering (small tier)

    @Test("Instructions render the current document excerpt in small tier")
    func instructionsIncludeExcerptSmallTier() async throws {
        let doc = makeDocument(title: "Important Note", content: "Key information here about widgets.")
        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let instructions = try await builder.buildInstructions(
            prompt: "test",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 2000, // small tier
            vaultName: "TestVault"
        )

        #expect(instructions.contains("[[Important Note]]"))
        #expect(instructions.contains("Key information here about widgets."))
    }

    // MARK: - Tier selection: medium

    @Test("Medium tier renders current doc and search result excerpts into one string")
    func instructionsMediumTierIncludesSearchResults() async throws {
        let doc = makeDocument(title: "Current Doc", content: "Current document content body.")
        let searchID = DocumentID()
        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc])

        await searchService.setSearchResults([
            makeSearchResult(documentID: searchID, title: "Related Note", excerpt: "Related content here body.")
        ])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let instructions = try await builder.buildInstructions(
            prompt: "some query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 8000, // medium tier
            vaultName: "TestVault"
        )

        // Both excerpts appear, distinguishing medium from small. The medium
        // tier caps the current doc at its own estimated token count, so its
        // content may be truncated at a word boundary — assert a stable prefix
        // rather than the full string.
        #expect(instructions.contains("[[Current Doc]]"))
        #expect(instructions.contains("Current document content"))
        #expect(instructions.contains("[[Related Note]]"))
        #expect(instructions.contains("Related content here"))
    }

    // MARK: - Tier selection: large

    @Test("Large tier renders graph neighbors into the instructions string")
    func instructionsLargeTierIncludesGraphNeighbors() async throws {
        let linkedID = DocumentID()
        let linkedDoc = makeDocument(
            id: linkedID,
            title: "Linked Note",
            content: "Linked content body text.",
            path: "notes/linked.md"
        )
        let doc = makeDocument(title: "Main Doc", content: "Main document body.", linkedDocumentIDs: [linkedID])

        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc, linkedDoc])
        await searchService.setSearchResults([])
        await searchService.setBacklinkMap([:])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let instructions = try await builder.buildInstructions(
            prompt: "query",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 64000, // large tier
            vaultName: "TestVault"
        )

        // Graph-neighbor inclusion is unique to the large tier.
        #expect(instructions.contains("[[Main Doc]]"))
        #expect(instructions.contains("[[Linked Note]]"))
        #expect(instructions.contains("Linked content body text."))
    }

    // MARK: - Consistency with buildContext

    @Test("buildInstructions equals the systemPrompt returned by buildContext")
    func instructionsMatchBuildContextSystemPrompt() async throws {
        let doc = makeDocument(title: "Note A", content: "Body for note A.")
        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)

        let context = try await builder.buildContext(
            prompt: "q",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 8000,
            vaultName: "TestVault"
        )
        let instructions = try await builder.buildInstructions(
            prompt: "q",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 8000,
            vaultName: "TestVault"
        )

        #expect(instructions == context.systemPrompt)
        // Every selected excerpt's content is represented in the instructions.
        for excerpt in context.excerpts {
            #expect(instructions.contains("[[" + excerpt.title + "]]"))
        }
    }

    // MARK: - Custom template

    @Test("Custom system-prompt template is honored and excerpts appended")
    func instructionsHonorCustomTemplate() async throws {
        let doc = makeDocument(title: "Tpl Note", content: "Template body content.")
        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let instructions = try await builder.buildInstructions(
            prompt: "q",
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 2000,
            vaultName: "VaultX",
            systemPromptTemplate: "CUSTOM PROMPT for {vault_name}."
        )

        #expect(instructions.contains("CUSTOM PROMPT for VaultX."))
        #expect(instructions.contains("[[Tpl Note]]"))
        #expect(instructions.contains("Template body content."))
    }

    // MARK: - Zero budget edge case

    @Test("Zero context budget still yields system prompt with no excerpts")
    func instructionsZeroBudget() async throws {
        let doc = makeDocument(content: "Content.")
        let searchService = StubSearchService()
        let repository = StubDocumentRepository(documents: [doc])

        let builder = ContextBuilder(searchService: searchService, repository: repository)
        let longPrompt = String(repeating: "word ", count: 5000)
        let instructions = try await builder.buildInstructions(
            prompt: longPrompt,
            scope: .global,
            currentDocumentID: doc.id,
            maxTokens: 1000,
            vaultName: "TestVault"
        )

        // System prompt is still present; no excerpt content was rendered.
        #expect(instructions.contains("TestVault"))
        #expect(instructions.contains("Knowledge base context:"))
        #expect(!instructions.contains("[[Content.]]"))
    }
}
