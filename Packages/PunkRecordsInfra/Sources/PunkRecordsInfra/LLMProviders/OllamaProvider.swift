import Foundation
import PunkRecordsCore

/// Client for a local Ollama server using its **native** API (`/api/chat`,
/// `/api/tags`). The native endpoint returns nanosecond timing fields, so we
/// surface server-accurate inference stats (TTFT, prefill rate, tokens/sec).
public actor OllamaProvider: LocalModelProvider {
    public nonisolated let id = LLMProviderID.ollama
    public nonisolated let displayName = "Ollama"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext, .functionCalls]
    public nonisolated let endpoint: URL

    public var maxContextTokens: Int { modelMaxTokens }
    public var selectedModel: String { modelID }

    private var modelID: String
    private var modelMaxTokens: Int

    /// - Parameters:
    ///   - endpoint: Ollama base URL (default `http://localhost:11434`).
    ///   - modelID: model name to send (e.g. `llama3:8b`). May be empty until
    ///     the user picks one from `availableModels()`.
    public init(
        endpoint: URL = URL(string: "http://localhost:11434")!,
        modelID: String = "",
        maxContextTokens: Int = 32_000
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.modelMaxTokens = maxContextTokens
    }

    public func setModel(_ id: String) async { modelID = id }

    // MARK: - Availability & discovery

    public func isAvailable() async -> Bool {
        // Reachable AND a model is selected — an unconfigured model would 404.
        guard !modelID.isEmpty else { return false }
        return await ping()
    }

    private func ping() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("/api/tags"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func availableModels() async throws -> [LocalModel] {
        let url = endpoint.appendingPathComponent("/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return LocalModelListParser.parseOllamaTags(data)
    }

    public func validate() async -> ProviderValidationResult {
        do {
            let models = try await availableModels()
            return ProviderValidationResult(isReachable: true, models: models)
        } catch {
            return .unreachable(Self.describe(error))
        }
    }

    public func benchmark(prompt: String) async -> InferenceStats? {
        let request = LLMRequest(userPrompt: prompt, streamResponse: false)
        return try? await complete(request).stats
    }

    // MARK: - Completion

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let messages = Self.encodeMessages(
            systemPrompt: request.systemPrompt,
            conversation: request.messages,
            fallbackUserPrompt: request.userPrompt,
            selectedText: request.selectedText
        )
        let json = try await postChat(messages: messages, tools: nil)
        let decoded = Self.decode(json, providerID: id)
        return LLMResponse(
            text: decoded.response.textContent,
            providerID: id,
            usage: decoded.response.usage,
            stats: decoded.response.stats
        )
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        let endpoint = self.endpoint
        let modelID = self.modelID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Build the (non-Sendable) messages array inside the task so it
                    // never crosses the sending-closure boundary.
                    let messages = Self.encodeMessages(
                        systemPrompt: request.systemPrompt,
                        conversation: request.messages,
                        fallbackUserPrompt: request.userPrompt,
                        selectedText: request.selectedText
                    )
                    let url = endpoint.appendingPathComponent("/api/chat")
                    let body: [String: Any] = [
                        "model": modelID,
                        "messages": messages,
                        "stream": true,
                        "options": [:] as [String: Any],
                    ]
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                    urlRequest.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LLMError.providerError("Ollama HTTP \(http.statusCode)")
                    }
                    // Ollama streams newline-delimited JSON objects (not SSE).
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let message = obj["message"] as? [String: Any],
                              let content = message["content"] as? String,
                              !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        let messages = Self.encodeMessages(
            systemPrompt: request.systemPrompt,
            conversation: request.messages,
            fallbackUserPrompt: request.userPrompt,
            selectedText: request.selectedText
        )
        let tools = request.tools.map { $0.map(Self.encodeTool) }
        let json = try await postChat(messages: messages, tools: tools)
        return Self.decode(json, providerID: id).response
    }

    // MARK: - HTTP

    private func postChat(messages: [[String: Any]], tools: [[String: Any]]?) async throws -> [String: Any] {
        let url = endpoint.appendingPathComponent("/api/chat")
        var body: [String: Any] = ["model": modelID, "messages": messages, "stream": false]
        if let tools, !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.providerError("Ollama: malformed response JSON")
        }
        return json
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.providerError("Ollama HTTP \(http.statusCode): \(body)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
            return "Can't reach Ollama. Is it running? (\(urlError.localizedDescription))"
        }
        return error.localizedDescription
    }

    // MARK: - Pure encode/decode (static for testability)

    /// Build the Ollama `messages` array from a system prompt + conversation
    /// history. Tool-result blocks become separate `role:"tool"` messages;
    /// tool-use blocks attach as `tool_calls` on the assistant message.
    static func encodeMessages(
        systemPrompt: String?,
        conversation: [ConversationMessage]?,
        fallbackUserPrompt: String,
        selectedText: String?
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }

        guard let conversation, !conversation.isEmpty else {
            let content = selectedText.map { "Selected text: \($0)\n\n\(fallbackUserPrompt)" } ?? fallbackUserPrompt
            messages.append(["role": "user", "content": content])
            return messages
        }

        for message in conversation {
            var textParts: [String] = []
            var toolCalls: [[String: Any]] = []
            var toolResults: [[String: Any]] = []

            for block in message.content {
                switch block {
                case .text(let text):
                    if !text.isEmpty { textParts.append(text) }
                case .toolUse(_, let name, let input):
                    toolCalls.append(["function": ["name": name, "arguments": input.toPlainDict()]])
                case .toolResult(_, let content, _):
                    toolResults.append(["role": "tool", "content": content])
                case .serverToolUse, .serverToolResult:
                    break // Ollama has no server-side tools.
                }
            }

            if !textParts.isEmpty || !toolCalls.isEmpty {
                var entry: [String: Any] = ["role": message.role.rawValue]
                entry["content"] = textParts.joined(separator: "\n")
                if !toolCalls.isEmpty { entry["tool_calls"] = toolCalls }
                messages.append(entry)
            }
            messages.append(contentsOf: toolResults)
        }
        return messages
    }

    static func encodeTool(_ tool: ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.inputSchema.toPlainDict(),
            ],
        ]
    }

    /// Decode an Ollama `/api/chat` (non-streaming) response into content blocks
    /// + stop reason + native stats.
    static func decode(_ json: [String: Any], providerID: LLMProviderID) -> (response: LLMToolResponse, text: String) {
        var blocks: [ContentBlock] = []
        let message = json["message"] as? [String: Any]

        if let content = message?["content"] as? String, !content.isEmpty {
            blocks.append(.text(content))
        }

        var hasToolCall = false
        if let toolCalls = message?["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let argsObject = function["arguments"] as? [String: Any] ?? [:]
                blocks.append(.toolUse(
                    id: UUID().uuidString,
                    name: name,
                    input: SendableValue.from(jsonObject: argsObject)
                ))
                hasToolCall = true
            }
        }

        let stopReason: StopReason = hasToolCall ? .toolUse : .endTurn

        let promptTokens = json["prompt_eval_count"] as? Int
        let completionTokens = json["eval_count"] as? Int
        let stats = InferenceStats.fromOllama(
            promptEvalCount: promptTokens,
            promptEvalDurationNanos: json["prompt_eval_duration"] as? Int,
            evalCount: completionTokens,
            evalDurationNanos: json["eval_duration"] as? Int,
            loadDurationNanos: json["load_duration"] as? Int
        )
        let usage: TokenUsage? = (promptTokens != nil || completionTokens != nil)
            ? TokenUsage(promptTokens: promptTokens ?? 0, completionTokens: completionTokens ?? 0)
            : nil

        let response = LLMToolResponse(
            contentBlocks: blocks,
            stopReason: stopReason,
            usage: usage,
            stats: stats
        )
        return (response, response.textContent)
    }
}
