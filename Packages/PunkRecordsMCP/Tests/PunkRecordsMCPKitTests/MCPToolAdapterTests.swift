import Foundation
import MCP
import PunkRecordsCore
import PunkRecordsTestSupport
import Testing
@testable import PunkRecordsMCPKit

@Suite("MCPToolAdapter — AgentTool <-> MCP wire type translation")
struct MCPToolAdapterTests {
    // MARK: - descriptor(for:) / inputSchema(for:)

    @Test("descriptor carries the tool's name and description through unchanged")
    func descriptorCarriesNameAndDescription() {
        let tool = ListDocumentsTool(repository: MockDocumentRepository())
        let descriptor = MCPToolAdapter.descriptor(for: tool)
        #expect(descriptor.name == "list_documents")
        #expect(descriptor.description == tool.description)
    }

    @Test("inputSchema encodes type, properties, and required as MCP Value")
    func inputSchemaShape() {
        let schema = ToolParameterSchema(
            properties: [
                "query": ToolProperty(type: "string", description: "Search text"),
            ],
            required: ["query"]
        )
        let value = MCPToolAdapter.inputSchema(for: schema)
        guard case let .object(dict) = value else {
            Issue.record("expected .object, got \(value)")
            return
        }
        #expect(dict["type"] == .string("object"))
        #expect(dict["required"] == .array([.string("query")]))
        guard case let .object(properties)? = dict["properties"],
              case let .object(queryProp)? = properties["query"] else {
            Issue.record("expected properties.query to be an object")
            return
        }
        #expect(queryProp["type"] == .string("string"))
        #expect(queryProp["description"] == .string("Search text"))
    }

    @Test("inputSchema encodes enum values on a property")
    func inputSchemaEnumValues() {
        let schema = ToolParameterSchema(
            properties: [
                "mode": ToolProperty(type: "string", description: "Mode", enumValues: ["a", "b"]),
            ],
            required: []
        )
        let value = MCPToolAdapter.inputSchema(for: schema)
        guard case let .object(dict) = value,
              case let .object(properties)? = dict["properties"],
              case let .object(modeProp)? = properties["mode"] else {
            Issue.record("unexpected shape: \(value)")
            return
        }
        #expect(modeProp["enum"] == .array([.string("a"), .string("b")]))
    }

    @Test("inputSchema encodes array-of-string items")
    func inputSchemaArrayItems() {
        let schema = ToolParameterSchema(
            properties: [
                "tags": ToolProperty(
                    type: "array",
                    description: "Tags",
                    items: ToolProperty(type: "string", description: "A tag")
                ),
            ],
            required: []
        )
        let value = MCPToolAdapter.inputSchema(for: schema)
        guard case let .object(dict) = value,
              case let .object(properties)? = dict["properties"],
              case let .object(tagsProp)? = properties["tags"],
              case let .object(itemsProp)? = tagsProp["items"] else {
            Issue.record("unexpected shape: \(value)")
            return
        }
        #expect(itemsProp["type"] == .string("string"))
    }

    // MARK: - decodeArguments(_:)

    @Test("decodeArguments is empty for nil arguments")
    func decodeArgumentsNil() {
        let decoded = MCPToolAdapter.decodeArguments(nil)
        #expect(decoded.isEmpty)
    }

    @Test("decodeArguments unwraps scalars, arrays, and nested objects")
    func decodeArgumentsScalarsAndNesting() {
        let wire: [String: Value] = [
            "title": .string("My Note"),
            "count": .int(3),
            "ratio": .double(1.5),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object(["nested": .string("value")]),
            "missing": .null,
        ]
        let decoded = MCPToolAdapter.decodeArguments(wire)
        #expect(decoded["title"] as? String == "My Note")
        #expect(decoded["count"] as? Int == 3)
        #expect(decoded["ratio"] as? Double == 1.5)
        #expect(decoded["active"] as? Bool == true)
        #expect(decoded["tags"] as? [String] == ["a", "b"])
        #expect((decoded["meta"] as? [String: Any])?["nested"] as? String == "value")
        #expect(decoded["missing"] is NSNull)
    }

    // MARK: - callResult(from:) / error helpers

    @Test("callResult encodes a successful ToolResult as non-error text content")
    func callResultSuccess() {
        let result = MCPToolAdapter.callResult(from: ToolResult(content: "ok", isError: false))
        #expect(result.isError == false)
        #expect(result.content == [.text(text: "ok", annotations: nil, _meta: nil)])
    }

    @Test("callResult encodes a failing ToolResult with isError = true")
    func callResultError() {
        let result = MCPToolAdapter.callResult(from: ToolResult(content: "bad", isError: true))
        #expect(result.isError == true)
        #expect(result.content == [.text(text: "bad", annotations: nil, _meta: nil)])
    }

    @Test("unknownToolResult names the offending tool and is an error")
    func unknownToolResultShape() {
        let result = MCPToolAdapter.unknownToolResult(name: "does_not_exist")
        #expect(result.isError == true)
        #expect(result.content == [.text(text: "Unknown tool: does_not_exist", annotations: nil, _meta: nil)])
    }

    // MARK: - Round trip through a real AgentTool

    @Test("round trip: wire arguments -> AgentTool.execute -> MCP result, for list_documents")
    func roundTripListDocuments() async throws {
        let repo = MockDocumentRepository(documents: [
            Document(title: "Note A", content: "# Note A", path: "Note A.md"),
        ])
        let tool = ListDocumentsTool(repository: repo)
        let arguments = MCPToolAdapter.decodeArguments([:])
        let toolResult = try await tool.execute(arguments: arguments)
        let mcpResult = MCPToolAdapter.callResult(from: toolResult)
        #expect(mcpResult.isError == false || mcpResult.isError == nil)
        guard case let .text(text, _, _)? = mcpResult.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("Note A"))
    }

    @Test("round trip: vault_search with a missing query argument surfaces as an error result")
    func roundTripSearchMissingQuery() async throws {
        let tool = VaultSearchTool(searchService: MockSearchService())
        let arguments = MCPToolAdapter.decodeArguments([:])
        let toolResult = try await tool.execute(arguments: arguments)
        let mcpResult = MCPToolAdapter.callResult(from: toolResult)
        #expect(mcpResult.isError == true)
    }
}
