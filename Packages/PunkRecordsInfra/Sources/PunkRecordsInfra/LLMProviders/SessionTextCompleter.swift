import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// Session-path implementation of the Core ``TextCompleter`` seam.
///
/// The completion backend for ``NoteCompiler``: drives an AnyLanguageModel
/// ``LanguageModelSession`` (via the shared ``SessionAgentRunner``) and
/// collapses the resulting ``AgentEvent`` stream back into one text blob —
/// exactly the "one prompt in → one text out" contract ``NoteCompiler`` needs.
///
/// No tools are attached: note compilation is a pure text-structuring step (the
/// prompt already carries all instructions and the source material), so there is
/// nothing for the model to call. Instructions default to empty for the same
/// reason; callers that want vault context can supply it.
///
/// Core stays pure — it names only ``TextCompleter``; this Infra type owns the
/// AnyLanguageModel import and the event→text reduction.
public struct SessionTextCompleter: TextCompleter {
    private let model: any LanguageModel
    private let instructions: String
    private let options: GenerationOptions

    /// - Parameters:
    ///   - model: The backing model (from ``LanguageModelFactory``) the session
    ///     drives.
    ///   - instructions: System prompt for the session. Defaults to empty because
    ///     ``NoteCompiler`` embeds all of its directions in the prompt itself.
    ///   - options: Generation options (sampling / max tokens).
    public init(
        model: any LanguageModel,
        instructions: String = "",
        options: GenerationOptions = GenerationOptions()
    ) {
        self.model = model
        self.instructions = instructions
        self.options = options
    }

    /// Run a single completion through the session and return the assembled text.
    ///
    /// Drives ``SessionAgentRunner`` with no tools and reduces its event stream:
    /// `.done(finalText:)` carries the full cumulative text (`SnapshotDeltaTracker`
    /// guarantees it equals the concatenation of every emitted `.textToken`), so we
    /// prefer it; we also accumulate tokens as a fallback in case a backend finishes
    /// without a terminal `.done`. An `.error` event is surfaced as a thrown error.
    public func complete(prompt: String) async throws -> String {
        let runner = SessionAgentRunner(
            model: model,
            instructions: instructions,
            tools: [],
            options: options
        )

        var accumulated = ""
        let stream = await runner.run(prompt: prompt)
        for try await event in stream {
            switch event {
            case .textToken(let delta):
                accumulated += delta
            case .done(let finalText):
                return finalText
            case .error(let agentError):
                throw agentError
            case .agentStart, .turnStart, .toolStart, .toolEnd, .turnEnd:
                continue
            }
        }
        return accumulated
    }
}
