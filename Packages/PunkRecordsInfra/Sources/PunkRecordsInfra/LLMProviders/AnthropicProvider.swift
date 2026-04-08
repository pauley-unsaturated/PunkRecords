import Foundation
import PunkRecordsCore

/// Anthropic Messages API client with streaming support.
public actor AnthropicProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.anthropic
    public nonisolated let displayName = "Anthropic Claude"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext]
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
            body["system"] = systemPrompt
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        let usage: TokenUsage?
        if let usageJSON = json?["usage"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: usageJSON["input_tokens"] as? Int ?? 0,
                completionTokens: usageJSON["output_tokens"] as? Int ?? 0
            )
        } else {
            usage = nil
        }

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
                        body["system"] = systemPrompt
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                    urlRequest.timeoutInterval = 120

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

    // MARK: - Private

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
