import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// Local-model inference via Hugging Face's AnyLanguageModel package, backed by
/// an Ollama HTTP server (default `http://localhost:11434`). AnyLanguageModel is
/// an API-compatible drop-in for Apple's FoundationModels, so we drive Ollama
/// through the same `LanguageModelSession` surface.
///
/// v1 supports text chat (`complete` + `stream`). Tool use is intentionally not
/// wired: AnyLanguageModel's session owns tool execution, whereas our `AgentLoop`
/// owns it and only needs the model's tool-call intent. Bridging that without
/// leaking the repository/search services into this provider is a follow-up
/// (see PUNK issue), so capabilities deliberately omit `.functionCalls`.
public actor AnyLanguageModelProvider: LLMProvider {
    public nonisolated let id = LLMProviderID.anyLanguageModel
    public nonisolated let displayName = "Local (Ollama)"
    public nonisolated let capabilities: LLMCapabilities = [.streaming, .onDevice]
    public var maxContextTokens: Int { modelMaxTokens }

    private let modelName: String
    private let endpoint: URL
    private let modelMaxTokens: Int

    public init(
        modelName: String = "qwen3",
        endpoint: URL = URL(string: "http://localhost:11434")!,
        maxContextTokens: Int = 8_192
    ) {
        self.modelName = modelName
        self.endpoint = endpoint
        self.modelMaxTokens = maxContextTokens
    }

    /// Available when the Ollama server answers. We probe `/api/tags` with a short
    /// timeout rather than assuming a running daemon — a reachable HTTP response
    /// (even an error status) means the server is up.
    public func isAvailable() async -> Bool {
        var req = URLRequest(url: endpoint.appendingPathComponent("/api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        do {
            let response = try await makeSession().respond(to: Self.buildPrompt(request))
            return LLMResponse(text: response.content, providerID: id, usage: nil)
        } catch {
            throw Self.mapError(error)
        }
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<String, Error> {
        let prompt = Self.buildPrompt(request)
        let endpoint = self.endpoint
        let modelName = self.modelName
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = OllamaLanguageModel(baseURL: endpoint, model: modelName)
                    let session = LanguageModelSession(model: model)
                    // AnyLanguageModel mirrors Apple's FoundationModels: each stream
                    // element is a *cumulative* snapshot, not a delta. We diff against
                    // the prefix already emitted so callers receive incremental tokens.
                    var emitted = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let full = partial.content
                        guard full.count > emitted.count, full.hasPrefix(emitted) else {
                            // Snapshot diverged from our running prefix (rare); emit
                            // the whole thing and resync.
                            if full != emitted { continuation.yield(full) }
                            emitted = full
                            continue
                        }
                        continuation.yield(String(full.dropFirst(emitted.count)))
                        emitted = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func makeSession() -> LanguageModelSession {
        let model = OllamaLanguageModel(baseURL: endpoint, model: modelName)
        return LanguageModelSession(model: model)
    }

    /// Fold the request into a single prompt string. Mirrors `AnthropicProvider`:
    /// the system prompt (which already carries vault context from `ContextBuilder`)
    /// is prepended, and selected text is surfaced ahead of the user prompt.
    static func buildPrompt(_ request: LLMRequest) -> String {
        var parts: [String] = []
        if let system = request.systemPrompt, !system.isEmpty {
            parts.append(system)
        }
        if let selected = request.selectedText, !selected.isEmpty {
            parts.append("Selected text: \(selected)")
        }
        parts.append(request.userPrompt)
        return parts.joined(separator: "\n\n")
    }

    private static func mapError(_ error: Error) -> Error {
        if error is LLMError { return error }
        return LLMError.providerError(String(describing: error))
    }
}
