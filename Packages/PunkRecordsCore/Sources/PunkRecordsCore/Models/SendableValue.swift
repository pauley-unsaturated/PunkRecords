import Foundation

// MARK: - Sendable JSON Value

/// Sendable wrapper for untyped JSON values, used to cross actor isolation boundaries
/// with tool arguments and definitions (``AgentTool/toJSONSchema()`` and the
/// Infra FoundationModels tool adapter both speak this type).
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
