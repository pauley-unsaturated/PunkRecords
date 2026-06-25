import Foundation

/// Orchestrates LLM-driven note creation: "save as note" from chat responses
/// and "compile from source" for turning raw material into wiki articles.
public actor NoteCompiler {
    private let completer: any TextCompleter
    private let repository: any DocumentRepository
    private let parser: MarkdownParser

    /// Designated initializer: depend on the minimal ``TextCompleter`` seam.
    ///
    /// The concrete completer is supplied from outside Core — the app injects a
    /// session-path implementation (Infra), evals/tests inject a mock or the
    /// legacy orchestrator. Core stays pure.
    public init(
        completer: any TextCompleter,
        repository: any DocumentRepository,
        parser: MarkdownParser = MarkdownParser()
    ) {
        self.completer = completer
        self.repository = repository
        self.parser = parser
    }

    /// Convenience initializer for callers that still hold an ``LLMOrchestrator``
    /// (legacy path / live evals). The orchestrator conforms to ``TextCompleter``
    /// via `complete(prompt:)`, so this is a thin forward to the designated init.
    public init(
        orchestrator: LLMOrchestrator,
        repository: any DocumentRepository,
        parser: MarkdownParser = MarkdownParser()
    ) {
        self.init(completer: orchestrator, repository: repository, parser: parser)
    }

    /// Creates a new note from an LLM response. The LLM generates title, tags, and wikilinks.
    /// Citations in the source (vault `[[wikilinks]]` and inline web `[Title](url)` links)
    /// are preserved end-to-end: the prompt instructs the model to keep them, and any
    /// dropped citations are appended as a "## Sources" section as a safety net.
    public func saveResponseAsNote(
        responseText: String,
        sourceDocumentID: DocumentID?,
        folderPath: RelativePath
    ) async throws -> Document {
        let sourceWikilinks = parser.parseWikilinks(from: responseText)
        let sourceWebLinks = parser.parseMarkdownLinks(from: responseText)

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
        - Preserve every citation present in the source text:
          - Keep all existing [[wikilinks]] to vault notes intact
          - Keep all existing web citations as inline markdown links [Title](url); never drop or rename them
        - Organize with clear sections (## headings) if the content warrants it
        - Keep the content faithful to the original; do not add information or invent sources
        - Output ONLY the markdown article, no preamble or explanation

        Text to convert:
        \(responseText)
        """

        let responseText = try await completer.complete(prompt: structurePrompt)

        var compiledBody = parser.parse(content: responseText, filename: "Untitled").body
        compiledBody = appendingMissingCitations(
            to: compiledBody,
            sourceWikilinks: sourceWikilinks,
            sourceWebLinks: sourceWebLinks
        )

        // Re-parse so the title is taken from the (possibly amended) body.
        let parsed = parser.parse(
            content: compiledBody,
            filename: "Untitled"
        )

        let id = DocumentID()
        let now = Date()
        let frontmatter = parser.generateFrontmatter(
            id: id,
            tags: parsed.tags,
            created: now,
            modified: now
        )

        let finalContent = frontmatter + "\n\n" + compiledBody
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

    /// Append a "## Sources" section if the compiled body dropped any of the
    /// citations present in the original text. Wikilinks match on `target`; web
    /// links match on URL (case-insensitive). The section is omitted when nothing
    /// is missing.
    private func appendingMissingCitations(
        to body: String,
        sourceWikilinks: [Wikilink],
        sourceWebLinks: [MarkdownLink]
    ) -> String {
        let bodyWikilinks = Set(parser.parseWikilinks(from: body).map { $0.target.lowercased() })
        let bodyURLs = Set(parser.parseMarkdownLinks(from: body).map { $0.url.lowercased() })

        let missingWikilinks = sourceWikilinks.filter { !bodyWikilinks.contains($0.target.lowercased()) }
        let missingWebLinks = sourceWebLinks.filter { !bodyURLs.contains($0.url.lowercased()) }

        guard !missingWikilinks.isEmpty || !missingWebLinks.isEmpty else {
            return body
        }

        var lines: [String] = []
        if !body.hasSuffix("\n\n") {
            lines.append(body.hasSuffix("\n") ? "" : "\n")
        }
        lines.append("## Sources")
        lines.append("")
        for link in missingWebLinks {
            lines.append("- [\(link.text)](\(link.url))")
        }
        for link in missingWikilinks {
            let display = link.displayText ?? link.target
            lines.append("- [[\(link.target)|\(display)]]")
        }
        return body + lines.joined(separator: "\n") + "\n"
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

        let compiledContent = try await completer.complete(prompt: compilePrompt)
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
