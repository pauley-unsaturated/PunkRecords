import Foundation
import PunkRecordsCore

/// Anthropic Messages API client with streaming and prompt caching support.
public actor AnthropicProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.anthropic
    public nonisolated let displayName = "Anthropic Claude"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext, .functionCalls]
    public var maxContextTokens: Int { modelMaxTokens }

    private let keychainService: KeychainService
    private let baseURL: URL
    private var modelID: String
    private var modelMaxTokens: Int

    public init(
        keychainService: KeychainService,
        modelID: String = "claude-sonnet-4-6",
        maxContextTokens: Int = 200_000,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.keychainService = keychainService
        self.modelID = modelID
        self.modelMaxTokens = maxContextTokens
        self.baseURL = baseURL
    }

    public func isAvailable() async -> Bool {
        (try? keychainService.apiKey(for: "anthropic")) != nil
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let apiKey = try requireAPIKey()
        let url = baseURL.appendingPathComponent("/v1/messages")

        var messages: [[String: Any]] = []
        if let selectedText = request.selectedText {
            messages.append(["role": "user", "content": "Selected text: \(selectedText)\n\n\(request.userPrompt)"])
        } else {
            messages.append(["role": "user", "content": request.userPrompt])
        }

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": 4096,
            "messages": messages,
        ]
        if let systemPrompt = request.systemPrompt {
            body["system"] = buildCacheableSystemPrompt(systemPrompt)
        }

        let urlRequest = try buildURLRequest(url: url, apiKey: apiKey, body: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        let usage = parseUsage(json)

        return LLMResponse(
            text: text,
            providerID: id,
            usage: usage
        )
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = try self.requireAPIKey()
                    let url = self.baseURL.appendingPathComponent("/v1/messages")

                    var messages: [[String: Any]] = []
                    if let selectedText = request.selectedText {
                        messages.append(["role": "user", "content": "Selected text: \(selectedText)\n\n\(request.userPrompt)"])
                    } else {
                        messages.append(["role": "user", "content": request.userPrompt])
                    }

                    var body: [String: Any] = [
                        "model": self.modelID,
                        "max_tokens": 4096,
                        "messages": messages,
                        "stream": true,
                    ]
                    if let systemPrompt = request.systemPrompt {
                        body["system"] = self.buildCacheableSystemPrompt(systemPrompt)
                    }

                    let urlRequest = try self.buildURLRequest(url: url, apiKey: apiKey, body: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    if let httpResponse = response as? HTTPURLResponse {
                        guard (200..<300).contains(httpResponse.statusCode) else {
                            throw self.errorForStatus(httpResponse.statusCode)
                        }
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }

                        guard let data = jsonStr.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        if let delta = event["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Tool Use

    public func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        let apiKey = try requireAPIKey()
        let url = baseURL.appendingPathComponent("/v1/messages")

        // Build messages from conversation history
        var messages: [[String: Any]] = []
        if let conversationMessages = request.messages {
            for msg in conversationMessages {
                var contentArray: [[String: Any]] = []
                for block in msg.content {
                    switch block {
                    case .text(let t):
                        contentArray.append(["type": "text", "text": t])
                    case .toolUse(let id, let name, let input):
                        contentArray.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": input.toPlainDict()
                        ])
                    case .toolResult(let toolUseID, let content, let isError):
                        var resultBlock: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": toolUseID,
                            "content": content
                        ]
                        if isError { resultBlock["is_error"] = true }
                        contentArray.append(resultBlock)
                    }
                }
                messages.append(["role": msg.role.rawValue, "content": contentArray])
            }
        } else {
            let userContent: String
            if let selectedText = request.selectedText {
                userContent = "Selected text: \(selectedText)\n\n\(request.userPrompt)"
            } else {
                userContent = request.userPrompt
            }
            messages.append(["role": "user", "content": userContent])
        }

        // Mark the last message block as cacheable so the entire conversation prefix
        // is cached at each turn. Subsequent turns read it from cache.
        markLastMessageCacheable(&messages)

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": 4096,
            "messages": messages,
        ]
        if let systemPrompt = request.systemPrompt {
            body["system"] = buildCacheableSystemPrompt(systemPrompt)
        }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = cacheableTools(tools)
        }

        let urlRequest = try buildURLRequest(url: url, apiKey: apiKey, body: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Parse content blocks
        var contentBlocks: [ContentBlock] = []
        if let content = json?["content"] as? [[String: Any]] {
            for block in content {
                let type = block["type"] as? String
                switch type {
                case "text":
                    if let text = block["text"] as? String {
                        contentBlocks.append(.text(text))
                    }
                case "tool_use":
                    if let blockID = block["id"] as? String,
                       let name = block["name"] as? String,
                       let input = block["input"] as? [String: Any] {
                        contentBlocks.append(.toolUse(
                            id: blockID,
                            name: name,
                            input: SendableValue.from(jsonObject: input)
                        ))
                    }
                default:
                    break
                }
            }
        }

        let stopReason = StopReason(rawValue: json?["stop_reason"] as? String ?? "end_turn") ?? .endTurn
        let usage = parseUsage(json)

        return LLMToolResponse(contentBlocks: contentBlocks, stopReason: stopReason, usage: usage)
    }

    // MARK: - Private

    /// Build a URLRequest with standard Anthropic headers.
    /// Prompt caching is GA — no beta header required.
    private func buildURLRequest(url: URL, apiKey: String, body: [String: Any]) throws -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        return urlRequest
    }

    /// Format system prompt as a single content block with cache_control.
    ///
    /// `cache_control` on the last block of the cacheable section caches everything
    /// up to and including that block. Per-conversation, the system prompt is stable,
    /// so caching the whole thing as one block is the right call.
    ///
    /// Note: Sonnet 4.6 requires ≥2048 tokens for the cache to actually be created.
    /// Smaller system prompts will silently bypass the cache.
    private func buildCacheableSystemPrompt(_ systemPrompt: String) -> [[String: Any]] {
        return [[
            "type": "text",
            "text": systemPrompt,
            "cache_control": ["type": "ephemeral"]
        ]]
    }

    /// Mark the last tool with cache_control so the entire tools array is cached.
    private func cacheableTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        return tools.enumerated().map { (idx, tool) -> [String: Any] in
            var def: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema.toPlainDict()
            ]
            if idx == tools.count - 1 {
                def["cache_control"] = ["type": "ephemeral"]
            }
            return def
        }
    }

    /// Add cache_control to the last content block of the last message.
    /// This caches the full conversation prefix at each turn — subsequent turns read it from cache.
    private func markLastMessageCacheable(_ messages: inout [[String: Any]]) {
        guard !messages.isEmpty else { return }
        guard var lastMessage = messages.last,
              var lastContent = lastMessage["content"] as? [[String: Any]],
              !lastContent.isEmpty else { return }
        var lastBlock = lastContent[lastContent.count - 1]
        lastBlock["cache_control"] = ["type": "ephemeral"]
        lastContent[lastContent.count - 1] = lastBlock
        lastMessage["content"] = lastContent
        messages[messages.count - 1] = lastMessage
    }

    /// Parse usage including prompt cache metrics from Anthropic API response.
    private func parseUsage(_ json: [String: Any]?) -> TokenUsage? {
        guard let usageJSON = json?["usage"] as? [String: Any] else { return nil }
        return TokenUsage(
            promptTokens: usageJSON["input_tokens"] as? Int ?? 0,
            completionTokens: usageJSON["output_tokens"] as? Int ?? 0,
            cacheCreationInputTokens: usageJSON["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadInputTokens: usageJSON["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    private func requireAPIKey() throws -> String {
        guard let key = try keychainService.apiKey(for: "anthropic"), !key.isEmpty else {
            throw LLMError.unauthorized
        }
        return key
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw LLMError.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.providerError(body)
        }
    }

    private func errorForStatus(_ code: Int) -> LLMError {
        switch code {
        case 401: return .unauthorized
        case 429: return .rateLimited(retryAfter: nil)
        default: return .providerError("HTTP \(code)")
        }
    }
}
