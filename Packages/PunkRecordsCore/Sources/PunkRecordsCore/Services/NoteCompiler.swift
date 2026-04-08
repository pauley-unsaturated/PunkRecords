import Foundation

/// Orchestrates LLM-driven note creation: "save as note" from chat responses
/// and "compile from source" for turning raw material into wiki articles.
public actor NoteCompiler {
    private let orchestrator: LLMOrchestrator
    private let repository: any DocumentRepository
    private let parser: MarkdownParser

    public init(
        orchestrator: LLMOrchestrator,
        repository: any DocumentRepository,
        parser: MarkdownParser = MarkdownParser()
    ) {
        self.orchestrator = orchestrator
        self.repository = repository
        self.parser = parser
    }

    /// Creates a new note from an LLM response. The LLM generates title, tags, and wikilinks.
    public func saveResponseAsNote(
        responseText: String,
        sourceDocumentID: DocumentID?,
        folderPath: RelativePath
    ) async throws -> Document {
        // Ask the LLM to structure the response as a wiki article
        let structurePrompt = """
        Convert the following text into a structured wiki article in markdown format.
        Requirements:
        - Start with YAML frontmatter in this exact format:
          ---
          tags: [tag1, tag2, tag3]
          ---
        - Follow the frontmatter with a descriptive H1 title (# Title)
        - Add [[wikilinks]] to concepts that could be their own notes
        - Organize with clear sections (## headings) if the content warrants it
        - Keep the content faithful to the original; do not add information
        - Output ONLY the markdown article, no preamble or explanation

        Text to convert:
        \(responseText)
        """

        let response = try await orchestrator.complete(
            prompt: structurePrompt,
            scope: .global
        )

        let compiledContent = response.text
        let parsed = parser.parse(content: compiledContent, filename: "Untitled")

        let id = DocumentID()
        let now = Date()
        let frontmatter = parser.generateFrontmatter(
            id: id,
            tags: parsed.tags,
            created: now,
            modified: now
        )

        let finalContent = frontmatter + "\n\n" + parsed.body
        let filename = sanitizeFilename(parsed.title) + ".md"
        let path = folderPath.isEmpty ? filename : folderPath + "/" + filename

        let document = Document(
            id: id,
            title: parsed.title,
            content: finalContent,
            path: path,
            tags: parsed.tags,
            created: now,
            modified: now,
            frontmatter: ["id": id.uuidString],
            linkedDocumentIDs: [] // Will be resolved on index
        )

        try await repository.save(document)
        return document
    }

    /// Compiles a source document into a structured wiki article.
    public func compileFromSource(
        sourceContent: String,
        sourceTitle: String,
        folderPath: RelativePath
    ) async throws -> Document {
        let compilePrompt = """
        You are compiling source material into a wiki article for a personal knowledge base.

        Source material title: \(sourceTitle)

        Instructions:
        - Start with YAML frontmatter in this exact format:
          ---
          tags: [tag1, tag2, tag3]
          ---
        - Follow the frontmatter with an H1 title (# Title) — can differ from the source title
        - Add [[wikilinks]] to key concepts that could be their own notes
        - Use clear sections (## headings), bullet points, and formatting as appropriate
        - Focus on extractable knowledge, not just summarization
        - If the source references other topics, link them with [[wikilinks]]
        - Output ONLY the markdown article, no preamble or explanation

        Source material:
        \(sourceContent)
        """

        let response = try await orchestrator.complete(
            prompt: compilePrompt,
            scope: .global
        )

        let compiledContent = response.text
        let parsed = parser.parse(content: compiledContent, filename: sourceTitle)

        let id = DocumentID()
        let now = Date()
        let frontmatter = parser.generateFrontmatter(
            id: id,
            tags: parsed.tags,
            created: now,
            modified: now
        )

        let finalContent = frontmatter + "\n\n" + parsed.body
        let filename = sanitizeFilename(parsed.title) + ".md"
        let path = folderPath.isEmpty ? filename : folderPath + "/" + filename

        let document = Document(
            id: id,
            title: parsed.title,
            content: finalContent,
            path: path,
            tags: parsed.tags,
            created: now,
            modified: now,
            frontmatter: ["id": id.uuidString],
            linkedDocumentIDs: []
        )

        try await repository.save(document)
        return document
    }

    // MARK: - Private

    private func sanitizeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: #"/\:*?"<>|"#)
        let sanitized = title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(100))
    }
}
