import Foundation

/// A minimal single-shot text-completion seam.
///
/// This is the entire LLM surface ``NoteCompiler`` needs: feed one fully-formed
/// prompt in, get one text blob out — no tools, no streaming, no usage metrics.
/// Keeping the dependency this small lets Core stay pure: the concrete
/// implementation (session path in Infra, or the legacy orchestrator) lives
/// outside Core and is injected.
///
/// Conformers must be `Sendable` because ``NoteCompiler`` is an actor and holds
/// one across isolation boundaries.
public protocol TextCompleter: Sendable {
    /// Run a single instructed completion and return the model's text.
    func complete(prompt: String) async throws -> String
}

// MARK: - Orchestrator adapter (legacy path)

/// Lets the legacy ``LLMOrchestrator`` stand in as a ``TextCompleter`` so callers
/// (and tests) that already hold an orchestrator can drive ``NoteCompiler``
/// unchanged. Routes through `complete(prompt:scope:)` with `.global` scope —
/// exactly the call ``NoteCompiler`` made before this seam existed — and returns
/// only the response text.
///
/// This keeps the strangler-fig honest: the orchestrator remains a valid backend
/// while the session path becomes the default in the app.
extension LLMOrchestrator: TextCompleter {
    public func complete(prompt: String) async throws -> String {
        let response = try await complete(prompt: prompt, scope: .global)
        return response.text
    }
}
