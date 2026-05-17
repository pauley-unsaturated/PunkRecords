import Foundation
import PunkRecordsCore

/// OpenAI Chat Completions API client with configurable base URL for Ollama/LM Studio.
public actor OpenAIProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.openAI
    public nonisolated let displayName: String
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext, .functionCalls]
    public var maxContextTokens: Int { modelMaxTokens }

    private let keychainService: KeychainService
    private let baseURL: URL
    private var modelID: String
    private var modelMaxTokens: Int

    /// Initialize for OpenAI API or any compatible endpoint.
    /// - Parameters:
    ///   - baseURL: The API base URL. Defaults to OpenAI. Use:
    ///     - `http://localhost:11434/v1` for Ollama
    ///     - `http://localhost:1234/v1` for LM Studio
    ///   - requiresAPIKey: If false (e.g. local server), skips key validation.
    private let requiresAPIKey: Bool

    public init(
        keychainService: KeychainService,
        modelID: String = "gpt-4o",
        maxContextTokens: Int = 128_000,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        displayName: String = "OpenAI",
        requiresAPIKey: Bool = true
    ) {
        self.keychainService = keychainService
        self.modelID = modelID
        self.modelMaxTokens = maxContextTokens
        self.baseURL = baseURL
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
    }

    public func isAvailable() async -> Bool {
        if requiresAPIKey {
            return (try? keychainService.apiKey(for: "openai")) != nil
        }
        return true
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let url = baseURL.appendingPathComponent("/chat/completions")
        let urlRequest = try buildRequest(url: url, request: request, stream: false)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""

        let usage: TokenUsage?
        if let usageJSON = json?["usage"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: usageJSON["prompt_tokens"] as? Int ?? 0,
                completionTokens: usageJSON["completion_tokens"] as? Int ?? 0
            )
        } else {
            usage = nil
        }

        return LLMResponse(text: text, providerID: id, usage: usage)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = self.baseURL.appendingPathComponent("/chat/completions")
                    let urlRequest = try self.buildRequest(url: url, request: request, stream: true)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw self.errorForStatus(http.statusCode)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }

                        guard let data = jsonStr.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        if let choices = event["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            continuation.yield(content)
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

    // MARK: - Responses API (tool-using calls)

    /// OpenAI's built-in `web_search` and the function-tool format both live on
    /// the Responses endpoint (`POST /v1/responses`), not Chat Completions.
    /// `complete()` and `stream()` stay on Chat Completions for compatibility
    /// with OpenAI-protocol-emulating local servers (Ollama, LM Studio).
    public func completeWithTools(_ request: LLMRequest) async throws -> LLMToolResponse {
        let url = baseURL.appendingPathComponent("/responses")

        var inputItems: [[String: Any]] = []

        if let conversation = request.messages, !conversation.isEmpty {
            inputItems.append(contentsOf: Self.encodeConversation(conversation))
        } else {
            let userContent: String
            if let selectedText = request.selectedText {
                userContent = "Selected text: \(selectedText)\n\n\(request.userPrompt)"
            } else {
                userContent = request.userPrompt
            }
            inputItems.append([
                "role": "user",
                "content": [["type": "input_text", "text": userContent]],
            ])
        }

        var body: [String: Any] = [
            "model": modelID,
            "input": inputItems,
            "store": false,
        ]
        if let systemPrompt = request.systemPrompt {
            body["instructions"] = systemPrompt
        }

        var tools: [[String: Any]] = []
        if let local = request.tools {
            tools.append(contentsOf: local.map(Self.encodeFunctionTool))
        }
        if let serverTools = request.serverTools {
            tools.append(contentsOf: Self.encodeServerTools(serverTools))
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        if requiresAPIKey {
            guard let key = try keychainService.apiKey(for: "openai"), !key.isEmpty else {
                throw LLMError.unauthorized
            }
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.providerError("OpenAI: malformed response JSON")
        }
        return Self.decodeResponse(json)
    }

    /// Translate ContentBlock-based conversation history into OpenAI's flat
    /// list of `input_item` objects. function_call / function_call_output items
    /// are siblings of user/assistant messages, not nested inside them.
    /// Exposed for tests via `static`; doesn't touch actor state.
    static func encodeConversation(_ messages: [ConversationMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            var contentParts: [[String: Any]] = []
            let isAssistant = message.role == .assistant
            for block in message.content {
                switch block {
                case .text(let text):
                    if isAssistant {
                        contentParts.append(["type": "output_text", "text": text])
                    } else {
                        contentParts.append(["type": "input_text", "text": text])
                    }
                case .toolUse(let id, let name, let input):
                    let argsData = (try? JSONSerialization.data(withJSONObject: input.toPlainDict())) ?? Data()
                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                    items.append([
                        "type": "function_call",
                        "call_id": id,
                        "name": name,
                        "arguments": argsString,
                    ])
                case .toolResult(let toolUseID, let content, _):
                    items.append([
                        "type": "function_call_output",
                        "call_id": toolUseID,
                        "output": content,
                    ])
                case .serverToolUse, .serverToolResult:
                    // Server-side tool blocks are provider artifacts; the model
                    // regenerates them as needed on the next turn.
                    break
                }
            }
            if !contentParts.isEmpty {
                items.append([
                    "role": message.role.rawValue,
                    "content": contentParts,
                ])
            }
        }
        return items
    }

    static func encodeFunctionTool(_ tool: ToolDefinition) -> [String: Any] {
        // Responses-API function tools are flat (no nested "function" wrapper).
        return [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.inputSchema.toPlainDict(),
        ]
    }

    static func encodeServerTools(_ tools: [ServerToolConfig]) -> [[String: Any]] {
        tools.map { tool in
            switch tool {
            case .webSearch:
                // maxUses isn't part of OpenAI's web_search spec — they cap it
                // internally and bill per call. Document but ignore the cap.
                return ["type": "web_search"]
            }
        }
    }

    static func decodeResponse(_ json: [String: Any]) -> LLMToolResponse {
        var contentBlocks: [ContentBlock] = []
        // Tracks the most-recent web_search_call id so we can attach a
        // synthetic .serverToolResult (with the URL citations the model
        // produced) once we encounter the message that consumed it.
        var pendingSearchCallID: String? = nil

        let outputItems = json["output"] as? [[String: Any]] ?? []
        for item in outputItems {
            let type = item["type"] as? String
            switch type {
            case "web_search_call":
                let id = item["id"] as? String ?? UUID().uuidString
                let query = extractWebSearchQuery(item)
                var input: [String: SendableValue] = [:]
                if let query { input["query"] = .string(query) }
                contentBlocks.append(.serverToolUse(id: id, name: "web_search", input: input))
                pendingSearchCallID = id

            case "message":
                let contentItems = item["content"] as? [[String: Any]] ?? []
                for part in contentItems {
                    guard let partType = part["type"] as? String else { continue }
                    if partType == "output_text" {
                        let text = part["text"] as? String ?? ""
                        let citations = extractURLCitations(part["annotations"])
                        if let searchID = pendingSearchCallID, !citations.isEmpty {
                            contentBlocks.append(.serverToolResult(
                                toolUseID: searchID,
                                content: formatCitations(citations),
                                isError: false
                            ))
                            pendingSearchCallID = nil
                        }
                        if !text.isEmpty {
                            contentBlocks.append(.text(text))
                        }
                    } else if partType == "refusal" {
                        let refusal = part["refusal"] as? String ?? "Refused"
                        contentBlocks.append(.text("[Refusal] \(refusal)"))
                    }
                }

            case "function_call":
                let callID = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
                let name = item["name"] as? String ?? ""
                let argsString = item["arguments"] as? String ?? "{}"
                let parsedInput: [String: SendableValue]
                if let argsData = argsString.data(using: .utf8),
                   let argsJSON = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    parsedInput = SendableValue.from(jsonObject: argsJSON)
                } else {
                    parsedInput = [:]
                }
                contentBlocks.append(.toolUse(id: callID, name: name, input: parsedInput))

            default:
                break
            }
        }

        // If the model ran a search but didn't cite any URLs, still emit a
        // serverToolResult so the UI's in-flight bubble flips to "completed".
        if let searchID = pendingSearchCallID {
            contentBlocks.append(.serverToolResult(
                toolUseID: searchID,
                content: "Search completed.",
                isError: false
            ))
        }

        // Map OpenAI's status field onto our StopReason. Stop reasons in
        // Responses live at the top level OR inside `output[].status`; we
        // use the rolled-up signal where available.
        let stopReason: StopReason
        let hasFunctionCall = contentBlocks.contains {
            if case .toolUse = $0 { return true } else { return false }
        }
        if hasFunctionCall {
            stopReason = .toolUse
        } else if let topStatus = json["status"] as? String, topStatus == "incomplete" {
            stopReason = .maxTokens
        } else {
            stopReason = .endTurn
        }

        let usage = parseUsage(json["usage"] as? [String: Any])
        return LLMToolResponse(contentBlocks: contentBlocks, stopReason: stopReason, usage: usage)
    }

    private static func extractWebSearchQuery(_ item: [String: Any]) -> String? {
        // OpenAI nests query under `action`. Older response shapes put it
        // at the top level under `query`. Try both for robustness.
        if let action = item["action"] as? [String: Any],
           let query = action["query"] as? String { return query }
        if let query = item["query"] as? String { return query }
        return nil
    }

    private static func extractURLCitations(_ raw: Any?) -> [(title: String, url: String)] {
        guard let annotations = raw as? [[String: Any]] else { return [] }
        return annotations.compactMap { annotation in
            guard annotation["type"] as? String == "url_citation",
                  let url = annotation["url"] as? String else { return nil }
            let title = annotation["title"] as? String ?? url
            return (title, url)
        }
    }

    private static func formatCitations(_ citations: [(title: String, url: String)]) -> String {
        // Dedupe by URL, preserving first-seen title.
        var seen = Set<String>()
        var lines: [String] = []
        for c in citations where !seen.contains(c.url) {
            seen.insert(c.url)
            lines.append("• \(c.title)\n  \(c.url)")
        }
        return lines.joined(separator: "\n\n")
    }

    private static func parseUsage(_ usageJSON: [String: Any]?) -> TokenUsage? {
        guard let usageJSON else { return nil }
        // Responses API uses input_tokens/output_tokens (not prompt/completion).
        let inputTokens = usageJSON["input_tokens"] as? Int
            ?? usageJSON["prompt_tokens"] as? Int ?? 0
        let outputTokens = usageJSON["output_tokens"] as? Int
            ?? usageJSON["completion_tokens"] as? Int ?? 0
        return TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
    }

    // MARK: - Private

    private func buildRequest(url: URL, request: LLMRequest, stream: Bool) throws -> URLRequest {
        var messages: [[String: String]] = []

        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        var userContent = request.userPrompt
        if let selectedText = request.selectedText {
            userContent = "Selected text: \(selectedText)\n\n\(request.userPrompt)"
        }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "stream": stream,
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120

        if requiresAPIKey {
            guard let key = try keychainService.apiKey(for: "openai"), !key.isEmpty else {
                throw LLMError.unauthorized
            }
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        return urlRequest
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw LLMError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
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
