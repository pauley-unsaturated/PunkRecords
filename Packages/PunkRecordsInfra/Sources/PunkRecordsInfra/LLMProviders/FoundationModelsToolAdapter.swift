import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// Bridges a PunkRecords Core ``AgentTool`` to AnyLanguageModel's `Tool`
/// protocol so a `LanguageModelSession` (which owns its own agentic tool loop)
/// can invoke our domain tools directly. This is the bridging seam: Core
/// stays pure (it knows nothing about FoundationModels / AnyLanguageModel), and
/// this Infra adapter does the one-way translation.
///
/// Design:
///   - `Arguments == GeneratedContent` so the schema is supplied dynamically
///     (we build `parameters` from the wrapped tool's `ToolParameterSchema`
///     rather than deriving it from a static `Generable` Swift type).
///   - `Output == String`, the simplest valid `PromptRepresentable` — we return
///     the `ToolResult.content` so the model reads the tool's text output.
///
/// The `parameters` schema is built once at init (it is invariant for a tool)
/// to avoid re-deriving it on every model turn.
struct FoundationModelsToolAdapter: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let wrapped: any AgentTool
    let name: String
    let description: String
    let parameters: GenerationSchema

    init(wrapping wrapped: any AgentTool) throws {
        self.wrapped = wrapped
        self.name = wrapped.name
        self.description = wrapped.description
        self.parameters = try Self.makeGenerationSchema(
            from: wrapped.parameterSchema,
            toolName: wrapped.name
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let decoded = Self.decodeArguments(arguments)
        let result = try await wrapped.execute(arguments: decoded)
        // Surface errors inline so the model can react to a failed tool call.
        // (FoundationModels has no separate error channel for tool output; the
        // text it reads is the only signal.)
        if result.isError {
            return "Error: \(result.content)"
        }
        return result.content
    }

    // MARK: - Schema mapping (pure, testable)

    /// Convert our `ToolParameterSchema` (a JSON-Schema-flavoured object) into an
    /// AnyLanguageModel `GenerationSchema` using the runtime `DynamicGenerationSchema`
    /// builders. Maps string / integer / number / boolean / array / string-enum
    /// properties and the `required` set.
    ///
    /// Enum (and any other named) sub-schemas are namespaced as
    /// `"<toolName>.<key>"` so distinct tools (and distinct properties within a
    /// tool) never collide into a `SchemaError.duplicateType`.
    static func makeGenerationSchema(
        from schema: ToolParameterSchema,
        toolName: String
    ) throws -> GenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = []
        // Stable ordering keeps generated schemas deterministic across runs.
        for key in schema.properties.keys.sorted() {
            guard let prop = schema.properties[key] else { continue }
            let dynamic = dynamicSchema(for: prop, namespace: "\(toolName).\(key)")
            properties.append(
                DynamicGenerationSchema.Property(
                    name: key,
                    description: prop.description,
                    schema: dynamic,
                    isOptional: !schema.required.contains(key)
                )
            )
        }
        let root = DynamicGenerationSchema(
            name: toolName,
            description: nil,
            properties: properties
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Map a single `ToolProperty` to a `DynamicGenerationSchema`.
    /// `namespace` is used as the name for any sub-schema that needs one (enums,
    /// nested array-of-enum) so names stay unique within the dependency set.
    private static func dynamicSchema(
        for property: ToolProperty,
        namespace: String
    ) -> DynamicGenerationSchema {
        switch property {
        case let .property(type, _, enumValues, items):
            switch type {
            case "string":
                if let enumValues, !enumValues.isEmpty {
                    return DynamicGenerationSchema(name: namespace, anyOf: enumValues)
                }
                return DynamicGenerationSchema(type: String.self)
            case "integer":
                return DynamicGenerationSchema(type: Int.self)
            case "number":
                return DynamicGenerationSchema(type: Double.self)
            case "boolean":
                return DynamicGenerationSchema(type: Bool.self)
            case "array":
                let itemSchema: DynamicGenerationSchema
                if let items {
                    itemSchema = dynamicSchema(for: items, namespace: "\(namespace).item")
                } else {
                    itemSchema = DynamicGenerationSchema(type: String.self)
                }
                return DynamicGenerationSchema(arrayOf: itemSchema)
            default:
                // Unknown / unsupported type — fall back to a free-form string
                // so schema construction never throws on an exotic type.
                return DynamicGenerationSchema(type: String.self)
            }
        }
    }

    // MARK: - Argument decoding (pure, testable)

    /// Decode a tool-call `GeneratedContent` (always a `.structure` for object
    /// schemas) into the `[String: Any]` shape `AgentTool.execute` expects.
    ///
    /// Numbers always arrive as `Double` (there is no integer kind in
    /// `GeneratedContent`); existing tools already tolerate this.
    static func decodeArguments(_ content: GeneratedContent) -> [String: Any] {
        guard case let .structure(properties, _) = content.kind else { return [:] }
        return properties.mapValues { plainValue(from: $0) }
    }

    /// Recursively unwrap a `GeneratedContent` into a Foundation-friendly value.
    static func plainValue(from content: GeneratedContent) -> Any {
        switch content.kind {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(elements):
            return elements.map { plainValue(from: $0) }
        case let .structure(properties, _):
            return properties.mapValues { plainValue(from: $0) }
        }
    }
}

// MARK: - Factory

/// Wrap a collection of Core ``AgentTool``s as AnyLanguageModel `Tool`s for use
/// when constructing a `LanguageModelSession(model:tools:...)`.
///
/// - Throws: Rethrows `GenerationSchema` construction errors (e.g. a malformed
///   parameter schema). Failing fast here is correct — a tool with an invalid
///   schema cannot participate in the session loop.
func makeFoundationModelsTools(from tools: [any AgentTool]) throws -> [any AnyLanguageModel.Tool] {
    try tools.map { try FoundationModelsToolAdapter(wrapping: $0) }
}
