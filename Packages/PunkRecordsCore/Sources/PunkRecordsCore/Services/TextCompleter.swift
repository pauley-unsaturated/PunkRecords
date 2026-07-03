import Foundation

/// A minimal single-shot text-completion seam.
///
/// This is the entire LLM surface ``NoteCompiler`` needs: feed one fully-formed
/// prompt in, get one text blob out — no tools, no streaming, no usage metrics.
/// Keeping the dependency this small lets Core stay pure: the concrete
/// implementation (the session path in Infra) lives outside Core and is
/// injected.
///
/// Conformers must be `Sendable` because ``NoteCompiler`` is an actor and holds
/// one across isolation boundaries.
public protocol TextCompleter: Sendable {
    /// Run a single instructed completion and return the model's text.
    func complete(prompt: String) async throws -> String
}
