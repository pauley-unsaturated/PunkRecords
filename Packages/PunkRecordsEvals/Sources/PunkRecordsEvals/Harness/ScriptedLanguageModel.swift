import AnyLanguageModel
import Foundation

/// A deterministic, no-network ``AnyLanguageModel/LanguageModel`` that replays a
/// canned script of assistant text and tool calls. It is the session-path
/// analogue of ``ScriptedProvider`` (which scripts the legacy `AgentLoop` via
/// `completeWithTools`): where `ScriptedProvider` feeds `LLMToolResponse`s into
/// the hand-rolled loop, `ScriptedLanguageModel` plays the role of the *model*
/// inside an AnyLanguageModel `LanguageModelSession` so the session's own tool
/// loop — and `SessionAgentRunner`'s event translation — can be exercised
/// end-to-end without an API key.
///
/// ## Why this conforms cleanly
/// - `UnavailableReason == Never`, so the `LanguageModel where UnavailableReason
///   == Never` extension auto-provides `availability == .available`; we don't
///   implement `availability`.
/// - `CustomGenerationOptions` is left defaulted to `Never`.
/// - `prewarm(...)` / `logFeedbackAttachment(...)` have protocol default impls.
/// - Only `respond(...)` and `streamResponse(...)` must be implemented, and
///   `SessionAgentRunner` only ever calls `streamResponse` with `Content == String`.
///
/// ## How tool calls fire events
/// The session passes its tools (each a `SessionAgentRunner.EventEmittingToolAdapter`)
/// to `streamResponse` via `session.tools`. A `.callTool` step looks the tool up
/// by name and invokes `tool.call(arguments:)` — exactly what
/// `OllamaLanguageModel` does in `resolveToolCalls`. Because the tool is wrapped
/// in the event-emitting adapter, that call drives the same `.toolStart` /
/// `.toolEnd` ``AgentEvent``s the live path emits. We append the tool's text
/// output to the running transcript-side text so later snapshots can reflect it,
/// but the scripted text steps are what the harness asserts on.
///
/// Snapshots are *cumulative* (the whole text so far), matching the contract
/// `SessionAgentRunner.SnapshotDeltaTracker` expects.
public struct ScriptedLanguageModel: LanguageModel {
    /// This model is always available (no network, no device gating).
    public typealias UnavailableReason = Never

    /// One step in the scripted response.
    public enum Step: Sendable {
        /// Emit a chunk of assistant text (streamed as a growing cumulative snapshot).
        case emitText(String)
        /// Invoke a tool by `name` with `arguments`, letting the session's tool
        /// adapter run it (and emit `.toolStart` / `.toolEnd`). The tool's text
        /// output is discarded for scripting determinism.
        case callTool(name: String, arguments: [String: GeneratedContentValue])
    }

    /// A minimal, `Sendable` JSON-ish value for scripting tool-call arguments,
    /// converted to ``GeneratedContent`` at call time. Mirrors the argument
    /// shapes tools expect (string / number / bool / array / object).
    public indirect enum GeneratedContentValue: Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([GeneratedContentValue])
        case object([String: GeneratedContentValue])

        var generated: GeneratedContent {
            switch self {
            case let .string(value):
                return GeneratedContent(value)
            case let .number(value):
                return GeneratedContent(value)
            case let .bool(value):
                return GeneratedContent(value)
            case let .array(elements):
                return GeneratedContent(kind: .array(elements.map(\.generated)))
            case let .object(properties):
                var dict: [String: GeneratedContent] = [:]
                var keys: [String] = []
                for key in properties.keys.sorted() {
                    dict[key] = properties[key]?.generated
                    keys.append(key)
                }
                return GeneratedContent(kind: .structure(properties: dict, orderedKeys: keys))
            }
        }
    }

    private let steps: [Step]

    /// - Parameter script: The ordered steps the model replays for the single
    ///   response it produces. Text steps concatenate into the final assistant
    ///   message; tool steps fire the session's tools in order.
    public init(script: [Step]) {
        self.steps = script
    }

    public func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        // Drive the same tool calls so non-streaming callers see consistent
        // behavior, then materialize the concatenated text. SessionAgentRunner
        // uses streamResponse, so this path is a faithful-but-secondary shim.
        let text = try await runSteps(in: session)
        if let stringContent = text as? Content {
            return LanguageModelSession.Response(
                content: stringContent,
                rawContent: GeneratedContent(text),
                transcriptEntries: []
            )
        }
        let generated = GeneratedContent(text)
        return LanguageModelSession.Response(
            content: try type.init(generated),
            rawContent: generated,
            transcriptEntries: []
        )
    }

    public func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let steps = self.steps
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task {
                do {
                    var cumulative = ""
                    for step in steps {
                        try Task.checkCancellation()
                        switch step {
                        case let .emitText(chunk):
                            cumulative += chunk
                            if let snapshot = Self.stringSnapshot(cumulative, as: Content.self) {
                                continuation.yield(snapshot)
                            }
                        case let .callTool(name, arguments):
                            // Find the matching session tool (the event-emitting
                            // adapter) and invoke it — this fires .toolStart/.toolEnd.
                            guard let tool = session.tools.first(where: { $0.name == name }) else {
                                continue
                            }
                            let args = Self.makeArguments(arguments)
                            // The session would wrap a throw in a ToolCallError; we
                            // let it propagate so the runner maps it the same way.
                            try await invoke(tool, with: args)
                        }
                    }
                    // A final cumulative snapshot guarantees the stream yields at
                    // least once even for a tool-only script (so .done carries the
                    // accumulated text).
                    if let snapshot = Self.stringSnapshot(cumulative, as: Content.self) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }

    // MARK: - Helpers

    /// Replay tool steps and concatenate text steps (used by the non-streaming shim).
    private func runSteps(in session: LanguageModelSession) async throws -> String {
        var cumulative = ""
        for step in steps {
            switch step {
            case let .emitText(chunk):
                cumulative += chunk
            case let .callTool(name, arguments):
                guard let tool = session.tools.first(where: { $0.name == name }) else { continue }
                try await invoke(tool, with: Self.makeArguments(arguments))
            }
        }
        return cumulative
    }

    /// Build a cumulative-text snapshot for the `Content == String` case.
    ///
    /// `SessionAgentRunner` only ever streams with `Content == String`, so this
    /// returns `nil` for any other `Content` (no structured-output script support
    /// is needed). Using a conditional cast keeps the model force-cast free.
    private static func stringSnapshot<Content>(
        _ text: String,
        as type: Content.Type
    ) -> LanguageModelSession.ResponseStream<Content>.Snapshot? where Content: Generable {
        guard let content = text as? Content else { return nil }
        return LanguageModelSession.ResponseStream<Content>.Snapshot(
            content: content.asPartiallyGenerated(),
            rawContent: GeneratedContent(text)
        )
    }

    /// Build a `.structure` `GeneratedContent` (what `AgentTool` adapters expect)
    /// from scripted argument values, with deterministic key ordering.
    private static func makeArguments(_ arguments: [String: GeneratedContentValue]) -> GeneratedContent {
        var dict: [String: GeneratedContent] = [:]
        var keys: [String] = []
        for key in arguments.keys.sorted() {
            dict[key] = arguments[key]?.generated
            keys.append(key)
        }
        return GeneratedContent(kind: .structure(properties: dict, orderedKeys: keys))
    }
}

// MARK: - Existential tool invocation

/// Invoke a `Tool` from an `any Tool` existential with `GeneratedContent`
/// arguments. `Tool` has associated types (`Arguments`/`Output`), so `call(...)`
/// can't be sent to the bare existential; this generic opens it. Every tool the
/// session sees here is built by ``SessionAgentRunner`` and pins
/// `Arguments == GeneratedContent`, so the conditional cast on `arguments`
/// (already a `GeneratedContent`) always succeeds for our adapters; any
/// hypothetical non-`GeneratedContent` tool is skipped rather than crashing.
private func invoke<T: AnyLanguageModel.Tool>(
    _ tool: T,
    with arguments: GeneratedContent
) async throws {
    guard let typed = arguments as? T.Arguments else { return }
    _ = try await tool.call(arguments: typed)
}
