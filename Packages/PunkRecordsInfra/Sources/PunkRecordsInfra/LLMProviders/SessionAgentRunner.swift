import AnyLanguageModel
import Foundation
import PunkRecordsCore

/// Drives an LLM agent through AnyLanguageModel's `LanguageModelSession` — which
/// owns its own agentic tool loop — and surfaces progress as PunkRecords Core
/// ``AgentEvent``s so existing UI (built against the `AgentLoop` event stream)
/// can consume it unchanged.
///
/// This is the strangler-fig replacement for the hand-rolled ``AgentLoop``: the
/// session, not us, decides when to call a tool and feeds results back. We only
/// observe and translate. Core stays pure — it never imports
/// FoundationModels / AnyLanguageModel; this Infra type does the one-way bridge.
///
/// Event mapping (mirrors what `AgentLoop` emits today):
///   - `.agentStart` once at the start;
///   - `.toolStart(name, args)` / `.toolEnd(name, result)` around each tool call,
///     emitted from inside the tool adapter's `call(...)` (the session invokes it);
///   - `.textToken(delta)` for each *incremental* slice of model text — the
///     session yields *cumulative* snapshots, so we diff against the text already
///     emitted (see ``SnapshotDeltaTracker``);
///   - `.done(finalText)` at the end; thrown errors finish the stream
///     (`.error` is also emitted first so passive UIs that only read events see it).
///
/// Tool activity reaches the stream by threading a `Sendable` event sink into
/// each wrapped tool. The session calls tools from its own isolation, so the sink
/// must be safe to invoke from anywhere — an `AsyncThrowingStream.Continuation`
/// (which is `Sendable`) satisfies that.
public actor SessionAgentRunner {
    private let model: any LanguageModel
    private let instructions: String
    private let tools: [any AgentTool]
    private let options: GenerationOptions

    /// - Parameters:
    ///   - model: A FoundationModels / AnyLanguageModel model (e.g.
    ///     `OllamaLanguageModel`) the session will drive.
    ///   - instructions: The system prompt (e.g. from `ContextBuilder`). Passed
    ///     straight to the session as its `instructions:`.
    ///   - tools: Core domain tools the session may call. Each is wrapped in an
    ///     event-emitting adapter built on the M1 ``FoundationModelsToolAdapter``.
    ///   - options: Generation options (sampling/temperature/max tokens).
    public init(
        model: any LanguageModel,
        instructions: String,
        tools: [any AgentTool],
        options: GenerationOptions = GenerationOptions()
    ) {
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.options = options
    }

    /// Run the agent on `prompt`, returning a stream of ``AgentEvent``s.
    ///
    /// The work runs on a child `Task` whose lifetime is tied to the stream:
    /// cancelling the consumer (dropping the stream) cancels the model call.
    public func run(prompt: String) -> AsyncThrowingStream<AgentEvent, Error> {
        let model = self.model
        let instructions = self.instructions
        let tools = self.tools
        let options = self.options

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.agentStart)

                    // Capture each tool's output so we can thread it into the NEXT
                    // round's prompt. This is load-bearing: AnyLanguageModel's Ollama
                    // backend is stateless — every `respond` sends only the latest
                    // prompt (no system/instructions, no history, no tool outputs) — so
                    // the loop must carry context forward itself.
                    let toolLog = ToolResultLog()
                    let wrappedTools: [any AnyLanguageModel.Tool] = try tools.map { tool in
                        try EventEmittingToolAdapter(wrapping: tool) { event in
                            if case .toolEnd(let name, let result) = event {
                                toolLog.append(name: name, output: result.content)
                            }
                            continuation.yield(event)
                        }
                    }

                    // Instructions (system prompt + vault excerpts) are folded into the
                    // per-round prompt rather than the session's `instructions:`, because
                    // the Ollama backend drops session instructions entirely.
                    let session = LanguageModelSession(model: model, tools: wrappedTools, instructions: "")

                    // The session runs a SINGLE model round per `respond` and does not
                    // loop, so the agentic loop lives here: a round that returns empty
                    // content means the model only called tools (their outputs are now in
                    // `toolLog`); we rebuild the prompt with those results and ask again.
                    // The first non-empty answer — or the round cap — ends the loop.
                    var finalText = ""
                    for round in 0..<Self.maxToolRounds {
                        try Task.checkCancellation()
                        let roundPrompt = Self.roundPrompt(
                            instructions: instructions,
                            userRequest: prompt,
                            toolResults: toolLog.snapshot(),
                            forceAnswer: round == Self.maxToolRounds - 1
                        )
                        let response = try await session.respond(to: roundPrompt, options: options)
                        let text = response.content
                        if !text.isEmpty {
                            continuation.yield(.textToken(text))
                            finalText = text
                            break
                        }
                    }

                    continuation.yield(.done(finalText: finalText))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.finish()
                } catch {
                    let mapped = Self.mapError(error)
                    continuation.yield(.error(mapped))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maximum number of model rounds (tool turns plus the final answer) before the
    /// loop gives up — bounds pathological or looping tool use.
    static let maxToolRounds = 8

    /// Build a self-contained prompt for one agent round. Because the backing model
    /// may be stateless (Ollama sends only the latest prompt), every round restates
    /// the instructions, the user request, and the results of any tools already
    /// called this turn — so the model always has the full picture.
    ///
    /// - Parameter forceAnswer: on the final allowed round, tell the model to answer
    ///   now without calling more tools, so the loop terminates with content.
    static func roundPrompt(
        instructions: String,
        userRequest: String,
        toolResults: [ToolResultLog.Entry],
        forceAnswer: Bool
    ) -> String {
        var parts: [String] = []
        if !instructions.isEmpty { parts.append(instructions) }
        parts.append("User request:\n\(userRequest)")

        if !toolResults.isEmpty {
            var block = "Results from tools you have already called this turn:\n"
            for entry in toolResults {
                block += "- \(entry.name): \(entry.output)\n"
            }
            parts.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if forceAnswer {
            parts.append("Answer the user's request now using the information above. Do NOT call any tools.")
        } else if toolResults.isEmpty {
            parts.append(
                "If you need information from the vault, call vault_search to find notes, "
                + "then read_document with an exact `path:` from a search result. Then answer the request."
            )
        } else {
            parts.append(
                "Now answer the user's request using these results. Call another tool only if you "
                + "genuinely need more information (e.g. a tool errored — fix the arguments and retry)."
            )
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Error mapping

    /// Translate a thrown error into a Core ``AgentError`` for the event stream.
    static func mapError(_ error: Error) -> AgentError {
        switch error {
        case let agentError as AgentError:
            return agentError
        case is CancellationError:
            return .cancelled
        case let toolCallError as LanguageModelSession.ToolCallError:
            return .toolExecutionFailed(
                toolName: toolCallError.tool.name,
                underlying: String(describing: toolCallError.underlyingError)
            )
        default:
            return .providerError(String(describing: error))
        }
    }
}

// MARK: - Event-emitting tool adapter

/// An AnyLanguageModel `Tool` that wraps a Core ``AgentTool`` and emits
/// ``AgentEvent`` tool activity around each invocation.
///
/// Schema construction and argument decoding are delegated to the M1
/// ``FoundationModelsToolAdapter`` (the established, unit-tested seam) so the two
/// adapters never drift. This adapter adds *only* the event bookends:
/// `.toolStart` *before* delegating to the wrapped tool and `.toolEnd` *after*.
///
/// `EventSink` is `@Sendable` because the session invokes `call(...)` from its
/// own isolation (and tool calls may run concurrently).
struct EventEmittingToolAdapter: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    /// A thread-safe channel for tool-activity events back to the runner.
    typealias EventSink = @Sendable (AgentEvent) -> Void

    private let base: FoundationModelsToolAdapter
    private let emit: EventSink

    var name: String { base.name }
    var description: String { base.description }
    var parameters: GenerationSchema { base.parameters }

    init(wrapping tool: any AgentTool, emit: @escaping EventSink) throws {
        self.base = try FoundationModelsToolAdapter(wrapping: tool)
        self.emit = emit
    }

    func call(arguments: GeneratedContent) async throws -> String {
        emit(.toolStart(name: base.name, arguments: arguments.jsonString))

        do {
            let output = try await base.call(arguments: arguments)
            // `base.call` already prefixes errored results with "Error:"; reflect
            // that back into the ToolResult so passive UIs see the error flag.
            let isError = output.hasPrefix("Error:")
            emit(.toolEnd(
                name: base.name,
                result: ToolResult(content: output, isError: isError)
            ))
            return output
        } catch {
            emit(.toolEnd(
                name: base.name,
                result: ToolResult(content: String(describing: error), isError: true)
            ))
            throw error
        }
    }
}

// MARK: - Tool result log

/// Thread-safe accumulator for tool outputs produced during one agent run, so the
/// runner can fold them into the next round's prompt. The session invokes tools
/// from its own isolation, so appends may arrive off the runner's task.
final class ToolResultLog: @unchecked Sendable {
    struct Entry: Sendable {
        let name: String
        let output: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(name: String, output: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(name: name, output: output))
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

// MARK: - Cumulative-snapshot → delta tracker (pure, unit-tested)

/// Converts a sequence of *cumulative* text snapshots (each the whole text so
/// far) into *incremental* deltas, so callers can emit token-by-token output.
///
/// Pure and value-typed: feed each snapshot's full text to ``delta(for:)`` and it
/// returns only the newly-appended suffix, tracking what has already been emitted.
///
/// Invariant: the concatenation of every non-empty delta returned, in order,
/// equals the last snapshot text (`emitted`) — and no character is emitted twice
/// for the common monotonic-growth case.
///
/// Resync: if a snapshot is *not* an extension of the running prefix (rare model
/// resends / corrections), the tracker resets and returns the whole new snapshot,
/// keeping `emitted` equal to the latest snapshot text. This mirrors the
/// prefix-diff logic in `AnyLanguageModelProvider.stream(_:)`.
struct SnapshotDeltaTracker {
    /// The full text emitted so far (concatenation of all returned deltas).
    private(set) var emitted: String = ""

    /// Return the incremental delta for `snapshot` (the cumulative text so far).
    ///
    /// - Returns: The newly-appended suffix for the normal append case; the whole
    ///   `snapshot` after a resync; or `""` if `snapshot` adds nothing.
    mutating func delta(for snapshot: String) -> String {
        if snapshot == emitted {
            return ""
        }
        if snapshot.hasPrefix(emitted) {
            // Normal monotonic growth: return only the new suffix.
            let delta = String(snapshot.dropFirst(emitted.count))
            emitted = snapshot
            return delta
        }
        // Snapshot diverged from our running prefix — resync to it wholesale.
        emitted = snapshot
        return snapshot
    }
}
