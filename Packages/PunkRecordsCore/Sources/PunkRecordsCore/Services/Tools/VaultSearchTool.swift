import Foundation

/// Searches the vault using full-text search and returns formatted results.
public struct VaultSearchTool: AgentTool, Sendable {
    public let name = "vault_search"
    public let description = "Search the knowledge base for notes matching a query. Returns titles, excerpts, and relevance scores."

    private let searchService: any SearchService

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "query": ToolProperty(type: "string", description: "Search query text")
            ],
            required: ["query"]
        )
    }

    public init(searchService: any SearchService) {
        self.searchService = searchService
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            return ToolResult(
                content: "Missing required 'query' parameter. Pass {\"query\": \"your search text\"}.",
                isError: true
            )
        }
        let results = try await searchService.search(query: query)
        guard !results.isEmpty else {
            return ToolResult(content: """
                No results found for '\(query)'. Try:
                - A broader or different query
                - list_documents to see what's in the vault
                """)
        }
        // Include path on each result so the agent can pass it directly to read_document.
        let formatted = results.prefix(10).map { r in
            let pathLine = r.path.isEmpty ? "" : "\n  path: \(r.path)"
            return "- **\(r.title)** (score: \(String(format: "%.2f", r.score)))\(pathLine)\n  \(r.excerpt.prefix(200))"
        }.joined(separator: "\n")
        return ToolResult(content: formatted)
    }
}
