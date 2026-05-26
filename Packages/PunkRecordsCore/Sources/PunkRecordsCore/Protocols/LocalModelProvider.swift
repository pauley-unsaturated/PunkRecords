import Foundation

/// An `LLMProvider` backed by a locally-hosted inference server (Ollama, LM
/// Studio). Adds model discovery, connection validation, a lightweight
/// benchmark, and live model switching on top of the base provider contract.
public protocol LocalModelProvider: LLMProvider {
    /// The server base URL this provider talks to.
    nonisolated var endpoint: URL { get }

    /// The model id currently selected for requests.
    var selectedModel: String { get }

    /// List the models the server currently has available.
    func availableModels() async throws -> [LocalModel]

    /// Probe the server: reachable? which models? Never throws — failures are
    /// folded into `ProviderValidationResult.errorMessage`.
    func validate() async -> ProviderValidationResult

    /// Run a tiny completion and report its measured inference stats. Returns
    /// `nil` if the call failed.
    func benchmark(prompt: String) async -> InferenceStats?

    /// Switch the model used by subsequent requests.
    func setModel(_ id: String) async
}
