import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

/// Unit tests for OpenAIProvider's Responses-API request/response shape.
/// Network calls are out of scope — these exercise the static encoders
/// and the response decoder against hand-built JSON dictionaries.
@Suite("OpenAIProvider Responses API")
struct OpenAIProviderResponsesTests {

    // MARK: - Server tools

    @Test("Server-tool web search encodes as {type: web_search}")
    func encodeWebSearchServerTool() {
        let encoded = OpenAIProvider.encodeServerTools([.webSearch(maxUses: 5)])
        #expect(encoded.count == 1)
        #expect(encoded.first?["type"] as? String == "web_search")
        // OpenAI doesn't expose max_uses on web_search — it should not leak through.
        #expect(encoded.first?["max_uses"] == nil)
    }

    // MARK: - Function tools

    @Test("Function tool encodes flat (no nested 'function' wrapper)")
    func encodeFunctionToolIsFlat() {
        let tool = ToolDefinition(
            name: "vault_search",
            description: "Search the vault",
            inputSchema: ["type": .string("object")]
        )
        let encoded = OpenAIProvider.encodeFunctionTool(tool)
        #expect(encoded["type"] as? String == "function")
        #expect(encoded["name"] as? String == "vault_search")
        #expect(encoded["description"] as? String == "Search the vault")
        #expect(encoded["parameters"] != nil)
        // The Chat-Completions shape wraps these in a `function: {...}` object;
        // Responses flattens them. Make sure we didn't accidentally wrap.
        #expect(encoded["function"] == nil)
    }

    // MARK: - Conversation encoding

    @Test("Conversation: user text becomes input_text on a user message item")
    func conversationUserMessageRoundTrips() {
        let history = [
            ConversationMessage(role: .user, content: [.text("Hello there")])
        ]
        let items = OpenAIProvider.encodeConversation(history)
        #expect(items.count == 1)
        #expect(items[0]["role"] as? String == "user")
        let content = items[0]["content"] as? [[String: Any]] ?? []
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "Hello there")
    }

    @Test("Conversation: assistant text becomes output_text")
    func conversationAssistantTextIsOutputText() {
        let history = [
            ConversationMessage(role: .assistant, content: [.text("Hi back")])
        ]
        let items = OpenAIProvider.encodeConversation(history)
        let content = items[0]["content"] as? [[String: Any]] ?? []
        #expect(content.first?["type"] as? String == "output_text")
    }

    @Test("Conversation: tool use + result split into sibling function_call / function_call_output items")
    func conversationFunctionCallsAreSiblings() {
        let history = [
            ConversationMessage(role: .assistant, content: [
                .toolUse(id: "call_abc", name: "vault_search", input: ["query": .string("swift")])
            ]),
            ConversationMessage(role: .user, content: [
                .toolResult(toolUseID: "call_abc", content: "Result text", isError: false)
            ]),
        ]
        let items = OpenAIProvider.encodeConversation(history)
        // 2 items: function_call, function_call_output. No wrapping messages
        // because both source messages had no .text blocks.
        #expect(items.count == 2)
        #expect(items[0]["type"] as? String == "function_call")
        #expect(items[0]["call_id"] as? String == "call_abc")
        #expect(items[0]["name"] as? String == "vault_search")
        // Arguments must be a JSON STRING for Responses, not an object.
        let argsString = items[0]["arguments"] as? String
        #expect(argsString != nil)
        let parsed = argsString.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        #expect(parsed["query"] as? String == "swift")

        #expect(items[1]["type"] as? String == "function_call_output")
        #expect(items[1]["call_id"] as? String == "call_abc")
        #expect(items[1]["output"] as? String == "Result text")
    }

    @Test("Conversation: server-tool blocks are dropped from re-sent history")
    func conversationDropsServerToolEchoes() {
        let history = [
            ConversationMessage(role: .assistant, content: [
                .serverToolUse(id: "ws_1", name: "web_search", input: ["query": .string("foo")]),
                .serverToolResult(toolUseID: "ws_1", content: "irrelevant", isError: false),
                .text("Final answer"),
            ])
        ]
        let items = OpenAIProvider.encodeConversation(history)
        #expect(items.count == 1, "Only the assistant message survives")
        let content = items[0]["content"] as? [[String: Any]] ?? []
        #expect(content.count == 1, "Server-tool blocks must be dropped, leaving only .text")
        #expect(content[0]["text"] as? String == "Final answer")
    }

    // MARK: - Response decoding

    @Test("Decode: plain text response becomes a single .text block")
    func decodePlainText() {
        let json: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Hello world", "annotations": [] as [Any]]
                    ],
                ]
            ],
            "usage": ["input_tokens": 12, "output_tokens": 5],
        ]
        let response = OpenAIProvider.decodeResponse(json)
        #expect(response.contentBlocks.count == 1)
        if case .text(let text) = response.contentBlocks[0] {
            #expect(text == "Hello world")
        } else {
            Issue.record("Expected .text, got \(response.contentBlocks[0])")
        }
        #expect(response.stopReason == .endTurn)
        #expect(response.usage?.promptTokens == 12)
        #expect(response.usage?.completionTokens == 5)
    }

    @Test("Decode: web_search_call + cited message emit serverToolUse / serverToolResult / text in order")
    func decodeWebSearchWithCitations() {
        let json: [String: Any] = [
            "output": [
                [
                    "type": "web_search_call",
                    "id": "ws_call_1",
                    "status": "completed",
                    "action": ["type": "search", "query": "latest swift release"],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "The latest stable Swift release is 6.0.",
                            "annotations": [
                                [
                                    "type": "url_citation",
                                    "url": "https://swift.org/download",
                                    "title": "Swift Downloads",
                                    "start_index": 0,
                                    "end_index": 5,
                                ]
                            ],
                        ]
                    ],
                ],
            ],
        ]
        let response = OpenAIProvider.decodeResponse(json)
        let shape: [String] = response.contentBlocks.map {
            switch $0 {
            case .text: return "text"
            case .serverToolUse(_, let name, _): return "serverToolUse(\(name))"
            case .serverToolResult: return "serverToolResult"
            case .toolUse: return "toolUse"
            case .toolResult: return "toolResult"
            }
        }
        #expect(shape == ["serverToolUse(web_search)", "serverToolResult", "text"])

        // The serverToolUse should carry the query as its input.
        if case .serverToolUse(_, _, let input) = response.contentBlocks[0] {
            #expect(input["query"] == .string("latest swift release"))
        } else {
            Issue.record("First block must be serverToolUse")
        }

        // The synthesized result should contain the cited URL + title.
        if case .serverToolResult(let toolUseID, let content, let isError) = response.contentBlocks[1] {
            #expect(toolUseID == "ws_call_1")
            #expect(content.contains("Swift Downloads"))
            #expect(content.contains("https://swift.org/download"))
            #expect(isError == false)
        } else {
            Issue.record("Second block must be serverToolResult")
        }
    }

    @Test("Decode: web_search_call with no follow-up citations still emits a result so the bubble completes")
    func decodeWebSearchWithoutCitations() {
        let json: [String: Any] = [
            "output": [
                [
                    "type": "web_search_call",
                    "id": "ws_call_empty",
                    "action": ["query": "no useful results"],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "I couldn't find anything.", "annotations": [] as [Any]]
                    ],
                ],
            ],
        ]
        let response = OpenAIProvider.decodeResponse(json)
        // Should have: serverToolUse, text, serverToolResult (synthesized at end).
        let hasUse = response.contentBlocks.contains { if case .serverToolUse = $0 { return true } else { return false } }
        let hasResult = response.contentBlocks.contains { if case .serverToolResult = $0 { return true } else { return false } }
        #expect(hasUse && hasResult,
                "UI's in-flight bubble needs the result block even when no URLs were cited")
    }

    @Test("Decode: function_call output item becomes .toolUse with parsed args and stop_reason=toolUse")
    func decodeFunctionCallStopsForTool() {
        let json: [String: Any] = [
            "output": [
                [
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_42",
                    "name": "vault_search",
                    "arguments": #"{"query":"swift concurrency"}"#,
                ]
            ],
        ]
        let response = OpenAIProvider.decodeResponse(json)
        #expect(response.stopReason == .toolUse)
        #expect(response.contentBlocks.count == 1)
        if case .toolUse(let id, let name, let input) = response.contentBlocks[0] {
            #expect(id == "call_42", "call_id is the right id for follow-up function_call_output")
            #expect(name == "vault_search")
            #expect(input["query"] == .string("swift concurrency"))
        } else {
            Issue.record("Expected .toolUse, got \(response.contentBlocks[0])")
        }
    }
}
