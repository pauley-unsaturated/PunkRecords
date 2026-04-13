import Foundation

/// Lists documents in the vault, optionally filtered to a specific folder.
public struct ListDocumentsTool: AgentTool, Sendable {
    public let name = "list_documents"
    public let description = "List documents in the knowledge base, optionally filtered to a folder."

    private let repository: any DocumentRepository

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "folder": ToolProperty(type: "string", description: "Folder path to list (omit or empty for all documents)")
            ],
            required: []
        )
    }

    public init(repository: any DocumentRepository) {
        self.repository = repository
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let folder = arguments["folder"] as? String
        let docs: [Document]
        if let folder, !folder.isEmpty {
            docs = try await repository.documentsInFolder(folder)
        } else {
            docs = try await repository.allDocuments()
        }
        let list = docs.prefix(50).map { "- \($0.title) (\($0.path))" }.joined(separator: "\n")
        let header = "Found \(docs.count) document\(docs.count == 1 ? "" : "s")"
        return ToolResult(content: list.isEmpty ? "No documents found" : "\(header):\n\(list)")
    }
}
