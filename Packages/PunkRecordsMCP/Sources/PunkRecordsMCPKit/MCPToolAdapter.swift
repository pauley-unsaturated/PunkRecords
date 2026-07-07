import Foundation
import MCP
import PunkRecordsCore

/// Translates between Core's `AgentTool` shapes and the MCP wire types
/// (`MCP.Tool`, `MCP.Value`, `MCP.CallTool.Result`). This is the one place
/// that knows about both worlds — Core stays free of MCP, and the MCP SDK
/// stays free of PunkRecords domain types. Every function here is pure (no
/// I/O, no actor hops) so it's unit-testable directly.
public enum MCPToolAdapter {
    // MARK: - Tool descriptor (tools/list)

    /// Builds the `tools/list` descriptor for a Core `AgentTool`.
    public static func descriptor(for tool: any AgentTool) -> Tool {
        Tool(
            name: tool.name,
            description: tool.description,
            inputSchema: inputSchema(for: tool.parameterSchema)
        )
    }

    /// Converts a `ToolParameterSchema` into an MCP JSON-Schema `Value`.
    public static func inputSchema(for schema: ToolParameterSchema) -> Value {
        var properties: [String: Value] = [:]
        for (key, property) in schema.properties {
            properties[key] = propertyValue(property)
        }
        return .object([
            "type": .string(schema.type),
            "properties": .object(properties),
            "required": .array(schema.required.map { .string($0) }),
        ])
    }

    private static func propertyValue(_ property: ToolProperty) -> Value {
        var dict: [String: Value] = [
            "type": .string(property.type),
            "description": .string(property.description),
        ]
        switch property {
        case let .property(_, _, enumValues, items):
            if let enumValues, !enumValues.isEmpty {
                dict["enum"] = .array(enumValues.map { .string($0) })
            }
            if let items {
                dict["items"] = propertyValue(items)
            }
        }
        return .object(dict)
    }

    // MARK: - Argument decoding (tools/call request)

    /// Decodes MCP wire arguments into the `[String: Any]` shape
    /// `AgentTool.execute(arguments:)` expects. Mirrors
    /// `FoundationModelsToolAdapter.decodeArguments` in Infra, which performs
    /// the analogous translation for the session-path tool loop.
    public static func decodeArguments(_ arguments: [String: Value]?) -> [String: Any] {
        guard let arguments else { return [:] }
        return arguments.mapValues { plainValue(from: $0) }
    }

    /// Recursively unwraps an MCP `Value` into a Foundation-friendly value.
    static func plainValue(from value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .data(_, let data):
            return data
        case .array(let arr):
            return arr.map { plainValue(from: $0) }
        case .object(let dict):
            return dict.mapValues { plainValue(from: $0) }
        }
    }

    // MARK: - Result encoding (tools/call response)

    /// Encodes a Core `ToolResult` as an MCP `CallTool.Result`. Tools here
    /// only ever produce text, so this always yields a single `.text` content
    /// block.
    public static func callResult(from result: ToolResult) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: result.content, annotations: nil, _meta: nil)],
            isError: result.isError
        )
    }

    /// A `CallTool.Result` for an unknown tool name (client asked for
    /// something not in our fixed four-tool set).
    public static func unknownToolResult(name: String) -> CallTool.Result {
        callResult(from: ToolResult(content: "Unknown tool: \(name)", isError: true))
    }

    /// A `CallTool.Result` for a tool that threw during execution.
    public static func executionFailureResult(name: String, error: Error) -> CallTool.Result {
        callResult(from: ToolResult(
            content: "Tool '\(name)' failed: \(error.localizedDescription)",
            isError: true
        ))
    }
}
