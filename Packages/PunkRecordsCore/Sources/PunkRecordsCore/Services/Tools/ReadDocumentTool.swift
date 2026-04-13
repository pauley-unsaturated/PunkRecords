import Foundation

/// Reads the full content of a document by its relative path.
public struct ReadDocumentTool: AgentTool, Sendable {
    public let name = "read_document"
    public let description = "Read the full content of a document by its relative path in the vault."

    private let repository: any DocumentRepository

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "path": ToolProperty(type: "string", description: "Relative path of the document (e.g. 'Notes/MyNote.md')")
            ],
            required: ["path"]
        )
    }

    public init(repository: any DocumentRepository) {
        self.repository = repository
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return ToolResult(
                content: "Missing required 'path' parameter. Pass {\"path\": \"relative/path.md\"}.",
                isError: true
            )
        }
        guard let doc = try await repository.document(atPath: path) else {
            return ToolResult(content: """
                Document not found at path: \(path)

                The path must match exactly (case-sensitive, including .md extension). To find \
                the correct path:
                - Use vault_search first; each result includes a `path:` line you can pass here.
                - Or use list_documents to browse the vault.
                """, isError: true)
        }
        let maxChars = 8000
        let content = doc.content.count > maxChars
            ? String(doc.content.prefix(maxChars)) + "\n\n[... truncated ...]"
            : doc.content
        return ToolResult(content: "# \(doc.title)\nPath: \(doc.path)\nTags: \(doc.tags.joined(separator: ", "))\n\n\(content)")
    }
}
