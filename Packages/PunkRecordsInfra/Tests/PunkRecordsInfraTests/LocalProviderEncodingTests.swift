import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

/// Unit tests for the pure request/response shaping of the local providers.
/// Network is out of scope — these exercise the static encoders/decoders
/// against hand-built JSON and conversation histories.
@Suite("Local provider encoding")
struct LocalProviderEncodingTests {

    // MARK: - Ollama messages

    @Test("Ollama: system + plain user prompt fallback")
    func ollamaFallbackUserPrompt() {
        let messages = OllamaProvider.encodeMessages(
            systemPrompt: "You are helpful.",
            conversation: nil,
            fallbackUserPrompt: "Hello",
            selectedText: nil
        )
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hello")
    }

    @Test("Ollama: selected text is prepended to the user prompt")
    func ollamaSelectedText() {
        let messages = OllamaProvider.encodeMessages(
            systemPrompt: nil,
            conversation: nil,
            fallbackUserPrompt: "Summarize",
            selectedText: "some excerpt"
        )
        #expect(messages.count == 1)
        let content = messages[0]["content"] as? String
        #expect(content?.contains("Selected text: some excerpt") == true)
        #expect(content?.contains("Summarize") == true)
    }

    @Test("Ollama: tool_use attaches to assistant, tool_result becomes a tool message")
    func ollamaToolRoundTrip() {
        let conversation: [ConversationMessage] = [
            ConversationMessage(role: .user, content: [.text("find notes")]),
            ConversationMessage(role: .assistant, content: [
                .text("searching"),
                .toolUse(id: "call-1", name: "vault_search", input: ["query": .string("foo")]),
            ]),
            ConversationMessage(role: .user, content: [
                .toolResult(toolUseID: "call-1", content: "3 hits", isError: false),
            ]),
        ]
        let messages = OllamaProvider.encodeMessages(
            systemPrompt: nil,
            conversation: conversation,
            fallbackUserPrompt: "",
            selectedText: nil
        )
        // user, assistant(+tool_calls), tool
        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "assistant")
        let toolCalls = messages[1]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        let function = toolCalls?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "vault_search")
        // Ollama arguments are a JSON object, not a string.
        #expect(function?["arguments"] is [String: Any])

        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["content"] as? String == "3 hits")
    }

    @Test("Ollama: decode parses content, tool calls, and native stats")
    func ollamaDecode() {
        let json: [String: Any] = [
            "message": [
                "role": "assistant",
                "content": "Here is the answer",
                "tool_calls": [
                    ["function": ["name": "read_document", "arguments": ["id": "abc"]]],
                ],
            ],
            "prompt_eval_count": 20,
            "prompt_eval_duration": 1_000_000_000, // 1s → 20 tok/s prefill
            "eval_count": 30,
            "eval_duration": 3_000_000_000,         // 3s → 10 tok/s
            "load_duration": 500_000_000,           // 0.5s
        ]
        let decoded = OllamaProvider.decode(json, providerID: .ollama).response
        #expect(decoded.textContent == "Here is the answer")
        #expect(decoded.stopReason == .toolUse)
        #expect(decoded.toolUseBlocks.first?.name == "read_document")
        #expect(decoded.usage?.promptTokens == 20)
        #expect(decoded.usage?.completionTokens == 30)
        #expect(decoded.stats?.source == .ollamaNative)
        #expect(abs((decoded.stats?.prefillRate ?? 0) - 20) < 0.001)
        #expect(abs((decoded.stats?.tokensPerSecond ?? 0) - 10) < 0.001)
        #expect(abs((decoded.stats?.timeToFirstToken ?? 0) - 1.5) < 0.001) // load + prefill
    }

    @Test("Ollama: plain text response stops with endTurn")
    func ollamaDecodeEndTurn() {
        let json: [String: Any] = ["message": ["content": "done"]]
        let decoded = OllamaProvider.decode(json, providerID: .ollama).response
        #expect(decoded.stopReason == .endTurn)
        #expect(decoded.toolUseBlocks.isEmpty)
    }

    // MARK: - LM Studio messages

    @Test("LM Studio: tool_use uses OpenAI shape with string arguments + tool_call_id")
    func lmStudioToolRoundTrip() {
        let conversation: [ConversationMessage] = [
            ConversationMessage(role: .assistant, content: [
                .toolUse(id: "call-9", name: "list_documents", input: ["limit": .int(5)]),
            ]),
            ConversationMessage(role: .user, content: [
                .toolResult(toolUseID: "call-9", content: "ok", isError: false),
            ]),
        ]
        let messages = LMStudioProvider.encodeMessages(
            systemPrompt: nil,
            conversation: conversation,
            fallbackUserPrompt: "",
            selectedText: nil
        )
        #expect(messages.count == 2)
        let toolCalls = messages[0]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == "call-9")
        #expect(toolCalls?.first?["type"] as? String == "function")
        let function = toolCalls?.first?["function"] as? [String: Any]
        // OpenAI arguments are a JSON-encoded string, not an object.
        #expect(function?["arguments"] is String)

        #expect(messages[1]["role"] as? String == "tool")
        #expect(messages[1]["tool_call_id"] as? String == "call-9")
        #expect(messages[1]["content"] as? String == "ok")
    }

    @Test("LM Studio: decode parses content, usage, and client-side stats")
    func lmStudioDecode() {
        let json: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": "Answer text"]],
            ],
            "usage": ["prompt_tokens": 12, "completion_tokens": 8],
        ]
        let start = Date(timeIntervalSince1970: 1000)
        let done = Date(timeIntervalSince1970: 1002) // 2s
        let decoded = LMStudioProvider.decode(json, requestStart: start, completedAt: done)
        #expect(decoded.textContent == "Answer text")
        #expect(decoded.stopReason == .endTurn)
        #expect(decoded.usage?.promptTokens == 12)
        #expect(decoded.stats?.source == .clientSide)
        #expect(decoded.stats?.timeToFirstToken == nil) // no streaming → no TTFT
        #expect(abs((decoded.stats?.tokensPerSecond ?? 0) - 4) < 0.001) // 8 / 2s
    }

    @Test("LM Studio: tool_calls in response set stopReason to toolUse")
    func lmStudioDecodeToolUse() {
        let json: [String: Any] = [
            "choices": [
                ["message": [
                    "tool_calls": [
                        ["id": "c1", "function": ["name": "vault_search", "arguments": "{\"query\":\"x\"}"]],
                    ],
                ]],
            ],
        ]
        let decoded = LMStudioProvider.decode(json, requestStart: Date(), completedAt: Date())
        #expect(decoded.stopReason == .toolUse)
        #expect(decoded.toolUseBlocks.first?.name == "vault_search")
        #expect(decoded.toolUseBlocks.first?.input["query"] == .string("x"))
    }
}
