import Testing
import PunkRecordsCore
import PunkRecordsTestSupport

@Suite("NoteCompiler Tests")
struct NoteCompilerTests {

    private func makeCompiler(
        llmResponse: String,
        documents: [Document] = []
    ) async -> (NoteCompiler, MockDocumentRepository) {
        let completer = MockTextCompleter(response: llmResponse)
        let repo = MockDocumentRepository(documents: documents)
        let compiler = NoteCompiler(completer: completer, repository: repo)
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

    @Test("Web citations in the source are kept when the LLM preserves them")
    func webCitationsKeptWhenLLMPreserves() async throws {
        let llmOutput = """
        ---
        tags: [swift]
        ---
        # Swift Concurrency

        Apple documents the model in [Swift concurrency](https://swift.org/concurrency).
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let source = "Apple documents the model in [Swift concurrency](https://swift.org/concurrency)."

        let doc = try await compiler.saveResponseAsNote(
            responseText: source,
            sourceDocumentID: nil,
            folderPath: ""
        )

        #expect(doc.content.contains("https://swift.org/concurrency"))
        // No backstop section needed when the LLM didn't drop anything.
        #expect(!doc.content.contains("## Sources"))
    }

    @Test("Dropped web citations are recovered in a Sources section")
    func droppedWebCitationsRecovered() async throws {
        // LLM strips the inline citation.
        let llmOutput = """
        ---
        tags: [swift]
        ---
        # Swift Concurrency

        Swift uses actors and async/await.
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let source = """
            Swift uses actors and async/await. See [Swift concurrency](https://swift.org/concurrency)
            and [WWDC 2021 transcript](https://developer.apple.com/wwdc21/10132) for details.
            """

        let doc = try await compiler.saveResponseAsNote(
            responseText: source,
            sourceDocumentID: nil,
            folderPath: ""
        )

        #expect(doc.content.contains("## Sources"))
        #expect(doc.content.contains("https://swift.org/concurrency"))
        #expect(doc.content.contains("https://developer.apple.com/wwdc21/10132"))
    }

    @Test("Dropped vault wikilinks are recovered in the Sources section")
    func droppedWikilinksRecovered() async throws {
        let llmOutput = """
        ---
        tags: [graphs]
        ---
        # Graph Theory Basics

        A graph is a set of nodes and edges.
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let source = """
            A graph is a set of nodes and edges. See [[Directed Graphs]] and
            [[Adjacency Lists]] for representations.
            """

        let doc = try await compiler.saveResponseAsNote(
            responseText: source,
            sourceDocumentID: nil,
            folderPath: ""
        )

        #expect(doc.content.contains("## Sources"))
        #expect(doc.content.contains("[[Directed Graphs"))
        #expect(doc.content.contains("[[Adjacency Lists"))
    }

    @Test("Citation backstop survives a partial drop")
    func citationBackstopOnPartialDrop() async throws {
        // LLM keeps one citation, drops the other.
        let llmOutput = """
        ---
        tags: [bio]
        ---
        # Mitosis

        Mitosis was first described in detail by [Walther Flemming](https://en.wikipedia.org/wiki/Walther_Flemming).
        """

        let (compiler, _) = await makeCompiler(llmResponse: llmOutput)
        let source = """
            Mitosis was first described in detail by
            [Walther Flemming](https://en.wikipedia.org/wiki/Walther_Flemming).
            For modern molecular detail, see [Cell cycle review](https://example.org/cell-cycle).
            """

        let doc = try await compiler.saveResponseAsNote(
            responseText: source,
            sourceDocumentID: nil,
            folderPath: ""
        )

        // Both URLs must end up in the final note exactly once.
        let occurrencesWalther = doc.content.components(separatedBy: "Walther_Flemming").count - 1
        let occurrencesCellCycle = doc.content.components(separatedBy: "example.org/cell-cycle").count - 1
        #expect(occurrencesWalther == 1)
        #expect(occurrencesCellCycle == 1)
        // Backstop fires because at least one citation was dropped.
        #expect(doc.content.contains("## Sources"))
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
