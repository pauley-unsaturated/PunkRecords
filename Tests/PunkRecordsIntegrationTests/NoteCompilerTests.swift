import Testing
import PunkRecordsCore
import PunkRecordsTestSupport

@Suite("NoteCompiler Tests")
struct NoteCompilerTests {

    private func makeCompiler(
        llmResponse: String,
        documents: [Document] = []
    ) async -> (NoteCompiler, MockDocumentRepository) {
        let mock = MockLLMProvider(capabilities: [], responses: [llmResponse])
        let search = MockSearchService()
        let repo = MockDocumentRepository(documents: documents)
        let contextBuilder = ContextBuilder(searchService: search, repository: repo)
        let orch = LLMOrchestrator(
            contextBuilder: contextBuilder,
            defaultProviderID: mock.id,
            vaultName: "TestVault"
        )
        await orch.registerProvider(mock)

        let compiler = NoteCompiler(orchestrator: orch, repository: repo)
        return (compiler, repo)
    }

    @Test("saveResponseAsNote creates a document from LLM response")
    func saveResponseAsNote() async throws {
        let llmOutput = """
        ---
        tags: [swift, testing]
        ---
        # Unit Testing in Swift

        Testing is important for [[software quality]].

        ## XCTest Framework

        Use XCTest for unit testing.
        """

        let (compiler, repo) = await makeCompiler(llmResponse: llmOutput)

        let doc = try await compiler.saveResponseAsNote(
            responseText: "some raw text about testing",
            sourceDocumentID: nil,
            folderPath: ""
        )

        #expect(!doc.title.isEmpty)
        #expect(!doc.content.isEmpty)
        #expect(doc.path.hasSuffix(".md"))

        let saved = await repo.saveCalls
        #expect(saved.count == 1)
        #expect(saved.first?.id == doc.id)
    }

    @Test("saveResponseAsNote places file in subfolder when specified")
    func saveResponseInSubfolder() async throws {
        let llmOutput = """
        ---
        tags: [notes]
        ---
        # My Note

        Content here.
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let doc = try await compiler.saveResponseAsNote(
            responseText: "raw text",
            sourceDocumentID: nil,
            folderPath: "wiki"
        )

        #expect(doc.path.hasPrefix("wiki/"))
    }

    @Test("compileFromSource creates a structured wiki article")
    func compileFromSource() async throws {
        let llmOutput = """
        ---
        tags: [concurrency, swift]
        ---
        # Swift Concurrency Guide

        An overview of [[async-await]] patterns.

        ## Structured Concurrency

        Task groups and child tasks.
        """

        let (compiler, repo) = await makeCompiler(llmResponse: llmOutput)

        let doc = try await compiler.compileFromSource(
            sourceContent: "Lots of raw notes about Swift concurrency...",
            sourceTitle: "Concurrency Notes",
            folderPath: ""
        )

        #expect(!doc.title.isEmpty)
        #expect(!doc.content.isEmpty)

        let saved = await repo.saveCalls
        #expect(saved.count == 1)
    }

    @Test("sanitizes invalid filename characters")
    func filenamesSanitized() async throws {
        let llmOutput = """
        ---
        tags: []
        ---
        # What/Why: A "Test" <Note>

        Content.
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let doc = try await compiler.saveResponseAsNote(
            responseText: "raw",
            sourceDocumentID: nil,
            folderPath: ""
        )

        #expect(!doc.path.contains("/"))
        #expect(!doc.path.contains("\""))
        #expect(!doc.path.contains("<"))
        #expect(!doc.path.contains(">"))
    }
}
