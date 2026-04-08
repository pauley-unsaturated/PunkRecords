import Foundation
import PunkRecordsCore

/// OpenAI Chat Completions API client with configurable base URL for Ollama/LM Studio.
public actor OpenAIProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.openAI
    public nonisolated let displayName: String
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .longContext]
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
