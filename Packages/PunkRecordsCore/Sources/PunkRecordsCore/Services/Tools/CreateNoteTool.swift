import Foundation

/// Creates a new markdown note in the vault with frontmatter.
public struct CreateNoteTool: AgentTool, Sendable {
    public let name = "create_note"
    public let description = "Create a new markdown note in the knowledge base with a title, content, and optional tags."

    private let repository: any DocumentRepository
    private let parser: MarkdownParser

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "title": ToolProperty(type: "string", description: "Title for the new note"),
                "content": ToolProperty(type: "string", description: "Markdown body content (without frontmatter)"),
                "folder": ToolProperty(type: "string", description: "Folder path to create the note in (empty string for vault root)"),
                "tags": ToolProperty(
                    type: "array",
                    description: "Tags for the note",
                    items: ToolProperty(type: "string", description: "A tag")
                )
            ],
            required: ["title", "content"]
        )
    }

    public init(repository: any DocumentRepository, parser: MarkdownParser = MarkdownParser()) {
        self.repository = repository
        self.parser = parser
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let title = arguments["title"] as? String, !title.isEmpty else {
            return ToolResult(
                content: "Missing or empty 'title' parameter. Pass {\"title\": \"...\", \"content\": \"markdown body\"}.",
                isError: true
            )
        }
        guard let content = arguments["content"] as? String, !content.isEmpty else {
            return ToolResult(
                content: "Missing or empty 'content' parameter. Provide the note's markdown body (without frontmatter — that's added automatically).",
                isError: true
            )
        }
        let folder = arguments["folder"] as? String ?? ""
        let tags = arguments["tags"] as? [String] ?? []

        let id = DocumentID()
        let now = Date()
        let frontmatter = parser.generateFrontmatter(id: id, tags: tags, created: now, modified: now)
        let fullContent = frontmatter + "\n\n# \(title)\n\n\(content)"
        let filename = sanitizeFilename(title) + ".md"
        let path = folder.isEmpty ? filename : folder + "/" + filename

        let document = Document(
            id: id,
            title: title,
            content: fullContent,
            path: path,
            tags: tags,
            created: now,
            modified: now,
            frontmatter: ["id": id.uuidString],
            linkedDocumentIDs: []
        )

        try await repository.save(document)
        return ToolResult(content: "Created note '\(title)' at \(path)")
    }

    private func sanitizeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: #"/\:*?"<>|"#)
        let sanitized = title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(100))
    }
}
