import Foundation
import MCP
import PunkRecordsCore
import PunkRecordsInfra

/// The four AgentTools PUNK-q9h exposes over MCP. `summarize_url` is
/// deliberately out of scope — its backing feature (web-content extraction)
/// is still under active development in other issues; see README.md.
public enum ServerFactory {
    /// Server version reported in the MCP `initialize` handshake and
    /// `--version`. Bump alongside meaningful behavior changes.
    public static let serverVersion = "1.0.0"

    /// Builds the fixed tool set backed by a vault's repository + search index.
    public static func makeTools(
        repository: any DocumentRepository,
        searchService: any SearchService
    ) -> [any AgentTool] {
        [
            VaultSearchTool(searchService: searchService),
            ReadDocumentTool(repository: repository),
            ListDocumentsTool(repository: repository),
            CreateNoteTool(repository: repository),
        ]
    }

    /// Builds an MCP `Server` with `tools/list` and `tools/call` handlers
    /// wired to `tools`, gated by `writable` (see `WritableGate`). Handlers
    /// are registered before the caller starts the transport, so no request
    /// can race ahead of registration.
    public static func makeServer(tools: [any AgentTool], writable: Bool) async -> Server {
        let server = Server(
            name: "punkrecords-mcp",
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let allNames = tools.map(\.name)

        await server.withMethodHandler(ListTools.self) { _ in
            let visibleNames = WritableGate.visibleToolNames(from: allNames, writable: writable)
            let descriptors = visibleNames.compactMap { toolsByName[$0] }.map(MCPToolAdapter.descriptor(for:))
            return ListTools.Result(tools: descriptors)
        }

        await server.withMethodHandler(CallTool.self) { params in
            if let rejection = WritableGate.rejection(forToolNamed: params.name, writable: writable) {
                return MCPToolAdapter.callResult(from: rejection)
            }
            guard let tool = toolsByName[params.name] else {
                return MCPToolAdapter.unknownToolResult(name: params.name)
            }
            let arguments = MCPToolAdapter.decodeArguments(params.arguments)
            do {
                let result = try await tool.execute(arguments: arguments)
                return MCPToolAdapter.callResult(from: result)
            } catch {
                return MCPToolAdapter.executionFailureResult(name: params.name, error: error)
            }
        }

        return server
    }
}
