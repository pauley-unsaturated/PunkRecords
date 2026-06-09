import Foundation
import PunkRecordsCore

/// Client for a local LM Studio server via its OpenAI-compatible API
/// (`/v1/chat/completions`, `/v1/models`). LM Studio doesn't report server-side
/// timing, so inference stats are measured **client-side** — full stats
/// (including TTFT) come from the streaming benchmark; the non-streaming chat
/// path reports tokens/sec from total elapsed time.
public actor LMStudioProvider: LocalModelProvider {
    public nonisolated let id = LLMProviderID.lmStudio
    public nonisolated let displayName = "LM Studio"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext, .functionCalls]
    public nonisolated let endpoint: URL

    public var maxContextTokens: Int { modelMaxTokens }
    public var selectedModel: String { modelID }

    private var modelID: String
    private var modelMaxTokens: Int

    /// - Parameters:
    ///   - endpoint: LM Studio base URL including `/v1` (default
    ///     `http://localhost:1234/v1`).
    public init(
        endpoint: URL = URL(string: "http://localhost:1234/v1")!,
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
        guard !modelID.isEmpty else { return false }
        return (try? await availableModels())?.isEmpty == false
    }

    public func availableModels() async throws -> [LocalModel] {
        let url = endpoint.appendingPathComponent("/models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return LocalModelListParser.parseOpenAIModels(data)
    }

    public func validate() async -> ProviderValidationResult {
        do {
            let models = try await availableModels()
            return ProviderValidationResult(isReachable: true, models: models)
        } catch {
            return .unreachable(Self.describe(error))
        }
    }

    /// Streaming benchmark: measures client-side TTFT and tokens/sec.
    public func benchmark(prompt: String) async -> InferenceStats? {
        let request = LLMRequest(userPrompt: prompt, streamResponse: true)
        let start = Date()
        var firstTokenAt: Date?
        var tokenCount = 0
        let stream = await stream(request)
        do {
            for try await token in stream {
                if firstTokenAt == nil { firstTokenAt = Date() }
                // Rough completion-token count (heuristic, ~ whitespace splits).
                tokenCount += max(1, token.split(whereSeparator: { $0 == " " || $0 == "\n" }).count)
            }
        } catch {
            return nil
        }
        return InferenceStats.fromClientTiming(
            requestStart: start,
            firstTokenAt: firstTokenAt,
            completedAt: Date(),
            promptTokens: nil,
            completionTokens: tokenCount
        )
    }

    // MARK: - Completion

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let messages = Self.encodeMessages(
            systemPrompt: request.systemPrompt,
            conversation: request.messages,
            fallbackUserPrompt: request.userPrompt,
            selectedText: request.selectedText
        )
        let start = Date()
        let json = try await postChat(messages: messages, tools: nil)
        let decoded = Self.decode(json, requestStart: start, completedAt: Date())
        return LLMResponse(
            text: decoded.textContent,
            providerID: id,
            usage: decoded.usage,
            stats: decoded.stats
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
                    let url = endpoint.appendingPathComponent("/chat/completions")
                    let body: [String: Any] = ["model": modelID, "messages": messages, "stream": true]
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                    urlRequest.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LLMError.providerError("LM Studio HTTP \(http.statusCode)")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]" else { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = event["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
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
        let start = Date()
        let json = try await postChat(messages: messages, tools: tools)
        return Self.decode(json, requestStart: start, completedAt: Date())
    }

    // MARK: - HTTP

    private func postChat(messages: [[String: Any]], tools: [[String: Any]]?) async throws -> [String: Any] {
        let url = endpoint.appendingPathComponent("/chat/completions")
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
            throw LLMError.providerError("LM Studio: malformed response JSON")
        }
        return json
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.providerError("LM Studio HTTP \(http.statusCode): \(body)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
            return "Can't reach LM Studio. Is the local server started? (\(urlError.localizedDescription))"
        }
        return error.localizedDescription
    }

    // MARK: - Pure encode/decode (static for testability)

    /// Build the OpenAI chat `messages` array. Assistant tool-use blocks become
    /// `tool_calls`; tool results become `role:"tool"` messages keyed by
    /// `tool_call_id`.
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
                case .toolUse(let id, let name, let input):
                    let argsData = (try? JSONSerialization.data(withJSONObject: input.toPlainDict())) ?? Data()
                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": argsString],
                    ])
                case .toolResult(let toolUseID, let content, _):
                    toolResults.append(["role": "tool", "tool_call_id": toolUseID, "content": content])
                case .serverToolUse, .serverToolResult:
                    break
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

    /// Decode an OpenAI `/chat/completions` (non-streaming) response, attaching
    /// client-side stats (no TTFT available without streaming).
    static func decode(_ json: [String: Any], requestStart: Date, completedAt: Date) -> LLMToolResponse {
        var blocks: [ContentBlock] = []
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]

        if let content = message?["content"] as? String, !content.isEmpty {
            blocks.append(.text(content))
        }

        var hasToolCall = false
        if let toolCalls = message?["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let id = call["id"] as? String ?? UUID().uuidString
                let argsString = function["arguments"] as? String ?? "{}"
                let parsed: [String: SendableValue]
                if let argsData = argsString.data(using: .utf8),
                   let argsJSON = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    parsed = SendableValue.from(jsonObject: argsJSON)
                } else {
                    parsed = [:]
                }
                blocks.append(.toolUse(id: id, name: name, input: parsed))
                hasToolCall = true
            }
        }

        let stopReason: StopReason = hasToolCall ? .toolUse : .endTurn

        let usageJSON = json["usage"] as? [String: Any]
        let promptTokens = usageJSON?["prompt_tokens"] as? Int
        let completionTokens = usageJSON?["completion_tokens"] as? Int
        let usage: TokenUsage? = usageJSON != nil
            ? TokenUsage(promptTokens: promptTokens ?? 0, completionTokens: completionTokens ?? 0)
            : nil
        let stats = InferenceStats.fromClientTiming(
            requestStart: requestStart,
            firstTokenAt: nil,
            completedAt: completedAt,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )

        return LLMToolResponse(contentBlocks: blocks, stopReason: stopReason, usage: usage, stats: stats)
    }
}
