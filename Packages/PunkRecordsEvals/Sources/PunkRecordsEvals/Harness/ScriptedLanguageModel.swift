import AnyLanguageModel
import Foundation

/// A deterministic, no-network ``AnyLanguageModel/LanguageModel`` that replays a
/// canned script of assistant text and tool calls. It plays the role of the
/// *model* behind an AnyLanguageModel `LanguageModelSession` so
/// `SessionAgentRunner`'s real round loop — tool-result folding, force-answer,
/// round cap — can be exercised end-to-end without an API key.
///
/// ## Rounds
/// `SessionAgentRunner` drives the session with one `respond` call per model
/// round: a round that produces no text means "the model only called tools",
/// so the runner folds the tool outputs into the next round's prompt and asks
/// again. Scripts mirror that shape: ``Step/endTurn`` closes a round, and each
/// `respond` replays exactly one round's steps (a shared cursor advances across
/// calls). A script with no `.endTurn` is a single round; once the script is
/// exhausted, further rounds return no text.
///
/// To simulate a multi-round agent, make every round before the last tool-only
/// (no `.emitText`), because the runner treats ANY returned text as the final
/// answer and stops looping — exactly like the shipping path.
///
/// ## Why this conforms cleanly
/// - `UnavailableReason == Never`, so the `LanguageModel where UnavailableReason
///   == Never` extension auto-provides `availability == .available`; we don't
///   implement `availability`.
/// - `CustomGenerationOptions` is left defaulted to `Never`.
/// - `prewarm(...)` / `logFeedbackAttachment(...)` have protocol default impls.
/// - Only `respond(...)` and `streamResponse(...)` must be implemented;
///   `SessionAgentRunner` drives `respond` (one call per round).
///
/// ## How tool calls fire events
/// The session passes its tools (each a `SessionAgentRunner.EventEmittingToolAdapter`)
/// to the model via `session.tools`. A `.callTool` step looks the tool up by
/// name and invokes `tool.call(arguments:)` — exactly what `OllamaLanguageModel`
/// does in `resolveToolCalls`. Because the tool is wrapped in the event-emitting
/// adapter, that call drives the same `.toolStart` / `.toolEnd` ``AgentEvent``s
/// the live path emits.
public struct ScriptedLanguageModel: LanguageModel {
    /// This model is always available (no network, no device gating).
    public typealias UnavailableReason = Never

    /// One step in the scripted response.
    public enum Step: Sendable {
        /// Emit a chunk of assistant text. Text chunks within a round concatenate
        /// into that round's response (streamed as growing cumulative snapshots
        /// on the `streamResponse` path).
        case emitText(String)
        /// Invoke a tool by `name` with `arguments`, letting the session's tool
        /// adapter run it (and emit `.toolStart` / `.toolEnd`).
        case callTool(name: String, arguments: [String: GeneratedContentValue])
        /// Close the current model round: `respond` returns the text accumulated
        /// so far this round, and the next `respond` resumes replay after this
        /// marker. A tool-only round returns no text, which keeps the runner's
        /// loop going — the mechanism multi-turn scenarios script against.
        case endTurn
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
    private let cursor = Cursor()

    /// - Parameter script: The ordered steps the model replays, one round per
    ///   `respond` call (rounds are delimited by ``Step/endTurn``). Copies of
    ///   the model share replay position, so one instance scripts one run.
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
        let text = try await runRound(in: session)
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
        let round = cursor.nextRound(from: steps)
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task {
                do {
                    var cumulative = ""
                    for step in round {
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
                        case .endTurn:
                            break // Unreachable: nextRound strips the delimiter.
                        }
                    }
                    // A final cumulative snapshot guarantees the stream yields at
                    // least once even for a tool-only round.
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

    /// Advance the cursor one round: replay its tool steps and concatenate its
    /// text steps (used by `respond`, the path `SessionAgentRunner` drives).
    private func runRound(in session: LanguageModelSession) async throws -> String {
        var cumulative = ""
        for step in cursor.nextRound(from: steps) {
            switch step {
            case let .emitText(chunk):
                cumulative += chunk
            case let .callTool(name, arguments):
                guard let tool = session.tools.first(where: { $0.name == name }) else { continue }
                try await invoke(tool, with: Self.makeArguments(arguments))
            case .endTurn:
                break // Unreachable: nextRound strips the delimiter.
            }
        }
        return cumulative
    }

    /// Shared replay position. A reference type so struct copies of the model
    /// (the session may copy it) advance the same script.
    private final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0

        /// Return the steps of the next un-replayed round (up to, excluding, the
        /// next `.endTurn`) and advance past it. Empty once the script is spent.
        func nextRound(from steps: [Step]) -> [Step] {
            lock.lock()
            defer { lock.unlock() }
            var round: [Step] = []
            while index < steps.count {
                let step = steps[index]
                index += 1
                if case .endTurn = step { break }
                round.append(step)
            }
            return round
        }
    }

    /// Build a cumulative-text snapshot for the `Content == String` case.
    ///
    /// The runner only ever generates `String` content, so this returns `nil`
    /// for any other `Content` (no structured-output script support is needed).
    /// Using a conditional cast keeps the model force-cast free.
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
