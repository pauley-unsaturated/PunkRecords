import AnyLanguageModel
import Foundation
import PunkRecordsCore
import Testing
@testable import PunkRecordsInfra

/// Unit tests for the FoundationModels/AnyLanguageModel tool adapter. These
/// exercise the pure, deterministic seams — schema mapping and argument
/// decoding — plus an end-to-end `call()` against a stub `AgentTool`. No model
/// or network is involved.
@Suite("FoundationModelsToolAdapter")
struct FoundationModelsToolAdapterTests {

    // A representative schema: a required string, an integer, a string enum, and
    // an array of strings. Exercises every branch of the schema mapper.
    private static func representativeSchema() -> ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "query": .property(type: "string", description: "Search query"),
                "limit": .property(type: "integer", description: "Max results"),
                "scope": .property(
                    type: "string",
                    description: "Where to search",
                    enumValues: ["all", "current", "linked"]
                ),
                "tags": .property(
                    type: "array",
                    description: "Filter tags",
                    items: .property(type: "string", description: "A tag")
                )
            ],
            required: ["query"]
        )
    }

    // MARK: - (a) Schema construction

    @Test("Building a GenerationSchema from a representative schema does not throw")
    func schemaBuildsWithoutThrowing() throws {
        _ = try FoundationModelsToolAdapter.makeGenerationSchema(
            from: Self.representativeSchema(),
            toolName: "vault_search"
        )
    }

    @Test("Built schema exposes the expected property names and required set")
    func schemaExposesPropertyNames() throws {
        let schema = try FoundationModelsToolAdapter.makeGenerationSchema(
            from: Self.representativeSchema(),
            toolName: "vault_search"
        )

        // GenerationSchema is Codable and encodes to JSON Schema. A named root
        // object lands in `$defs/<toolName>`; resolve it to inspect properties.
        let data = try JSONEncoder().encode(schema)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let defs = try #require(json["$defs"] as? [String: Any])
        let rootDef = try #require(defs["vault_search"] as? [String: Any])

        #expect(rootDef["type"] as? String == "object")

        let properties = try #require(rootDef["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["query", "limit", "scope", "tags"])

        let required = try #require(rootDef["required"] as? [String])
        #expect(Set(required) == ["query"])

        // The integer property keeps its integer type.
        let limit = try #require(properties["limit"] as? [String: Any])
        #expect(limit["type"] as? String == "integer")

        // The array property is typed as an array.
        let tags = try #require(properties["tags"] as? [String: Any])
        #expect(tags["type"] as? String == "array")
    }

    @Test("Distinct tools with same property names produce non-colliding schemas")
    func namespacingAvoidsDuplicateTypeErrors() throws {
        let schema = ToolParameterSchema(
            properties: [
                "mode": .property(type: "string", description: "Mode", enumValues: ["a", "b"])
            ],
            required: ["mode"]
        )
        // Two enum sub-schemas from two tools must not collide when each is built
        // independently; both should construct cleanly.
        _ = try FoundationModelsToolAdapter.makeGenerationSchema(from: schema, toolName: "tool_one")
        _ = try FoundationModelsToolAdapter.makeGenerationSchema(from: schema, toolName: "tool_two")
    }

    // MARK: - (b) Argument decoding

    @Test("Decoding a GeneratedContent structure yields the matching [String: Any]")
    func decodesArgumentsToDictionary() {
        let content = GeneratedContent(properties: [
            "query": "wikilinks",
            "limit": 5,
            "scope": "all",
            "enabled": true
        ])

        let decoded = FoundationModelsToolAdapter.decodeArguments(content)

        #expect(decoded["query"] as? String == "wikilinks")
        #expect(decoded["scope"] as? String == "all")
        #expect(decoded["enabled"] as? Bool == true)
        // Numbers always decode as Double (no integer kind in GeneratedContent).
        #expect(decoded["limit"] as? Double == 5.0)
    }

    @Test("Decoding handles nested arrays and objects")
    func decodesNestedContent() {
        let content = GeneratedContent(properties: [
            "tags": GeneratedContent(elements: ["swift", "macos"] as [any ConvertibleToGeneratedContent]),
            "nested": GeneratedContent(properties: ["k": "v"])
        ])

        let decoded = FoundationModelsToolAdapter.decodeArguments(content)

        let tags = try? #require(decoded["tags"] as? [Any])
        #expect(tags?.count == 2)
        #expect(tags?.first as? String == "swift")

        let nested = decoded["nested"] as? [String: Any]
        #expect(nested?["k"] as? String == "v")
    }

    @Test("Decoding a non-structure GeneratedContent yields an empty dictionary")
    func decodesNonStructureToEmpty() {
        #expect(FoundationModelsToolAdapter.decodeArguments(GeneratedContent("just a string")).isEmpty)
    }

    // MARK: - (c) call() round-trip against a stub AgentTool

    /// Records the arguments it was called with and returns a fixed result.
    private final class RecordingTool: AgentTool, @unchecked Sendable {
        let name = "recording_tool"
        let description = "Records its arguments for assertions"
        let parameterSchema = ToolParameterSchema(
            properties: ["query": .property(type: "string", description: "q")],
            required: ["query"]
        )

        // @unchecked Sendable: tests are single-threaded; this box just captures.
        private let box = Box()
        final class Box: @unchecked Sendable { var received: [String: Any]? }
        var received: [String: Any]? { box.received }

        let result: ToolResult
        init(result: ToolResult) { self.result = result }

        func execute(arguments: [String: Any]) async throws -> ToolResult {
            box.received = arguments
            return result
        }
    }

    @Test("call() decodes args, invokes the wrapped tool, and returns its text")
    func callInvokesWrappedToolAndReturnsText() async throws {
        let tool = RecordingTool(result: ToolResult(content: "found 3 notes"))
        let adapter = try FoundationModelsToolAdapter(wrapping: tool)

        let args = GeneratedContent(properties: ["query": "wikilinks", "limit": 7])
        let output = try await adapter.call(arguments: args)

        #expect(output == "found 3 notes")
        #expect(tool.received?["query"] as? String == "wikilinks")
        #expect(tool.received?["limit"] as? Double == 7.0)
    }

    @Test("call() surfaces an errored ToolResult inline with an Error prefix")
    func callSurfacesErrorResult() async throws {
        let tool = RecordingTool(result: ToolResult(content: "no such note", isError: true))
        let adapter = try FoundationModelsToolAdapter(wrapping: tool)

        let output = try await adapter.call(arguments: GeneratedContent(properties: ["query": "x"]))

        #expect(output == "Error: no such note")
    }

    @Test("Adapter mirrors the wrapped tool's name and description")
    func adapterMirrorsNameAndDescription() throws {
        let tool = RecordingTool(result: ToolResult(content: "ok"))
        let adapter = try FoundationModelsToolAdapter(wrapping: tool)

        #expect(adapter.name == "recording_tool")
        #expect(adapter.description == "Records its arguments for assertions")
    }

    @Test("Factory wraps every tool")
    func factoryWrapsAllTools() throws {
        let tools: [any AgentTool] = [
            RecordingTool(result: ToolResult(content: "a")),
            RecordingTool(result: ToolResult(content: "b"))
        ]
        let wrapped = try makeFoundationModelsTools(from: tools)
        #expect(wrapped.count == 2)
    }
}
