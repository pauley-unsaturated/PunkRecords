import Foundation

// MARK: - Tool Protocol

/// A tool the LLM can invoke during an agent loop.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameterSchema: ToolParameterSchema { get }
    func execute(arguments: [String: Any]) async throws -> ToolResult
}

// MARK: - Parameter Schema

/// JSON Schema description of a tool's input parameters.
/// Maps directly to Anthropic's `input_schema` format.
public struct ToolParameterSchema: Sendable {
    public let type: String
    public let properties: [String: ToolProperty]
    public let required: [String]

    public init(type: String = "object", properties: [String: ToolProperty], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    /// Convert to JSON Schema dictionary in SendableValue form for wire serialization.
    public func toJSONSchema() -> [String: SendableValue] {
        var props: [String: SendableValue] = [:]
        for (key, prop) in properties {
            props[key] = prop.toJSONSchema()
        }
        return [
            "type": .string(type),
            "properties": .object(props),
            "required": .array(required.map { .string($0) })
        ]
    }
}

/// A single property in a tool parameter schema.
public indirect enum ToolProperty: Sendable {
    case property(type: String, description: String, enumValues: [String]? = nil, items: ToolProperty? = nil)

    public var type: String {
        switch self { case .property(let t, _, _, _): return t }
    }

    public var description: String {
        switch self { case .property(_, let d, _, _): return d }
    }

    public init(type: String, description: String, enumValues: [String]? = nil, items: ToolProperty? = nil) {
        self = .property(type: type, description: description, enumValues: enumValues, items: items)
    }

    func toJSONSchema() -> SendableValue {
        switch self {
        case .property(let type, let description, let enumValues, let items):
            var dict: [String: SendableValue] = [
                "type": .string(type),
                "description": .string(description)
            ]
            if let enums = enumValues {
                dict["enum"] = .array(enums.map { .string($0) })
            }
            if let items {
                dict["items"] = items.toJSONSchema()
            }
            return .object(dict)
        }
    }
}

// MARK: - Tool Result

/// Result returned by a tool execution.
public struct ToolResult: Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}
