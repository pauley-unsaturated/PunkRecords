import Foundation

// MARK: - Sendable JSON Value

/// Sendable wrapper for untyped JSON values, used to cross actor isolation boundaries
/// with tool arguments and definitions.
public enum SendableValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SendableValue])
    case object([String: SendableValue])
    case null

    public static func from(jsonObject: [String: Any]) -> [String: SendableValue] {
        jsonObject.mapValues { fromAny($0) }
    }

    public static func fromAny(_ value: Any) -> SendableValue {
        // Check Bool before numeric types — Foundation bridges JSON booleans as NSNumber
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool(b)
        }
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let arr as [Any]: return .array(arr.map { fromAny($0) })
        case let dict as [String: Any]: return .object(from(jsonObject: dict))
        default: return .null
        }
    }

    public func toPlainValue() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let arr): return arr.map { $0.toPlainValue() }
        case .object(let dict): return dict.mapValues { $0.toPlainValue() }
        case .null: return NSNull()
        }
    }
}

extension [String: SendableValue] {
    public func toPlainDict() -> [String: Any] {
        mapValues { $0.toPlainValue() }
    }
}

// MARK: - Content Blocks

/// A content block in a multi-turn LLM conversation supporting tool use.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: SendableValue])
    case toolResult(toolUseID: String, content: String, isError: Bool)
}

// MARK: - Conversation Messages

public enum ConversationRole: String, Sendable {
    case user
    case assistant
}

/// A message in a multi-turn conversation with tool use support.
public struct ConversationMessage: Sendable {
    public let role: ConversationRole
    public let content: [ContentBlock]

    public init(role: ConversationRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Tool Definitions

/// Wire-format tool definition sent to the LLM provider.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: SendableValue]

    public init(name: String, description: String, inputSchema: [String: SendableValue]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Tool Response

public enum StopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
}

/// Response from a provider that may contain tool use blocks.
public struct LLMToolResponse: Sendable {
    public let contentBlocks: [ContentBlock]
    public let stopReason: StopReason
    public let usage: TokenUsage?

    public init(contentBlocks: [ContentBlock], stopReason: StopReason, usage: TokenUsage?) {
        self.contentBlocks = contentBlocks
        self.stopReason = stopReason
        self.usage = usage
    }

    public var textContent: String {
        contentBlocks.compactMap {
            if case .text(let t) = $0 { return t } else { return nil }
        }.joined()
    }

    public var toolUseBlocks: [(id: String, name: String, input: [String: SendableValue])] {
        contentBlocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 {
                return (id, name, input)
            }
            return nil
        }
    }
}
