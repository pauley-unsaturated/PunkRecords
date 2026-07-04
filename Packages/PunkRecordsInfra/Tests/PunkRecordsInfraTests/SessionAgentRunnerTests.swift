import AnyLanguageModel
import Foundation
import PunkRecordsCore
import Testing
@testable import PunkRecordsInfra

/// Unit tests for the session-driven agent runner. The live model/network path
/// is not automatable here, so these exercise the *pure, deterministic* seams:
/// the cumulative-snapshot → delta tracker, error mapping, and the
/// event-emitting tool adapter's bookend behaviour.
@Suite("SessionAgentRunner")
struct SessionAgentRunnerTests {

    // MARK: - SnapshotDeltaTracker (the load-bearing pure helper)

    /// Feed a sequence of cumulative snapshots through the tracker and collect the
    /// emitted deltas (skipping empties, as the runner does).
    private func deltas(for snapshots: [String]) -> (deltas: [String], finalEmitted: String) {
        var tracker = SnapshotDeltaTracker()
        var collected: [String] = []
        for snapshot in snapshots {
            let delta = tracker.delta(for: snapshot)
            if !delta.isEmpty { collected.append(delta) }
        }
        return (collected, tracker.emitted)
    }

    @Test("Deltas concatenate to the final cumulative snapshot")
    func deltasConcatenateToFinal() {
        let snapshots = ["", "Hello", "Hello, ", "Hello, world", "Hello, world!"]
        let (collected, finalEmitted) = deltas(for: snapshots)

        #expect(collected.joined() == "Hello, world!")
        #expect(finalEmitted == "Hello, world!")
    }

    @Test("Each delta is exactly the newly-appended suffix; no character emitted twice")
    func deltasAreNonOverlappingSuffixes() {
        let snapshots = ["The", "The quick", "The quick brown", "The quick brown fox"]
        let (collected, finalEmitted) = deltas(for: snapshots)

        // First snapshot "The" is the whole text (emitted was empty), so it is the
        // leading delta; the rest are non-overlapping appended suffixes.
        #expect(collected == ["The", " quick", " brown", " fox"])
        #expect(collected.joined() == "The quick brown fox")
        #expect(finalEmitted == "The quick brown fox")
    }

    @Test("The very first non-empty snapshot is emitted whole")
    func firstSnapshotEmittedWhole() {
        let (collected, finalEmitted) = deltas(for: ["Hello, world!"])
        #expect(collected == ["Hello, world!"])
        #expect(finalEmitted == "Hello, world!")
    }

    @Test("Repeated identical snapshots emit nothing after the first")
    func identicalSnapshotsAreIdempotent() {
        let snapshots = ["abc", "abc", "abc", "abcd"]
        let (collected, finalEmitted) = deltas(for: snapshots)

        #expect(collected == ["abc", "d"])
        #expect(finalEmitted == "abcd")
    }

    @Test("Leading empty snapshots emit nothing")
    func leadingEmptySnapshots() {
        let (collected, finalEmitted) = deltas(for: ["", "", "go"])
        #expect(collected == ["go"])
        #expect(finalEmitted == "go")
    }

    @Test("A diverging (non-prefix) snapshot resyncs to the whole new text")
    func divergingSnapshotResyncs() {
        // Model resends/corrects: "Hello" then a fresh "Goodbye" that is NOT a
        // prefix extension. Tracker resyncs and the final emitted equals the last.
        var tracker = SnapshotDeltaTracker()
        #expect(tracker.delta(for: "Hello") == "Hello")
        let resync = tracker.delta(for: "Goodbye")
        #expect(resync == "Goodbye")
        #expect(tracker.emitted == "Goodbye")
    }

    @Test("Final emitted always equals the last snapshot text, for any growth pattern")
    func finalEmittedMatchesLastSnapshot() {
        let cases: [[String]] = [
            ["", "a", "ab", "abc"],
            ["x"],
            ["one", "one two", "one two three"],
            ["", "", "", "done"],
            ["start", "started", "started!"]
        ]
        for snapshots in cases {
            let (_, finalEmitted) = deltas(for: snapshots)
            #expect(finalEmitted == (snapshots.last ?? ""))
        }
    }

    @Test("Unicode (multi-byte) growth diffs by character, not byte")
    func unicodeDeltaByCharacter() {
        let snapshots = ["caf", "café", "café ☕"]
        let (collected, finalEmitted) = deltas(for: snapshots)
        #expect(collected == ["caf", "é", " ☕"])
        #expect(finalEmitted == "café ☕")
    }

    // MARK: - Error mapping

    @Test("AgentError passes through unchanged")
    func mapsAgentErrorUnchanged() {
        let mapped = SessionAgentRunner.mapError(AgentError.maxIterationsExceeded(7))
        guard case .maxIterationsExceeded(let n) = mapped else {
            Issue.record("expected maxIterationsExceeded, got \(mapped)")
            return
        }
        #expect(n == 7)
    }

    @Test("CancellationError maps to .cancelled")
    func mapsCancellation() {
        let mapped = SessionAgentRunner.mapError(CancellationError())
        guard case .cancelled = mapped else {
            Issue.record("expected .cancelled, got \(mapped)")
            return
        }
    }

    @Test("Unknown errors map to .providerError")
    func mapsUnknownToProviderError() {
        struct Boom: Error {}
        let mapped = SessionAgentRunner.mapError(Boom())
        guard case .providerError = mapped else {
            Issue.record("expected .providerError, got \(mapped)")
            return
        }
    }

    // MARK: - EventEmittingToolAdapter bookends

    private final class StubTool: AgentTool, @unchecked Sendable {
        let name: String
        let description = "stub"
        let parameterSchema = ToolParameterSchema(
            properties: ["query": .property(type: "string", description: "q")],
            required: ["query"]
        )
        let result: ToolResult
        init(name: String = "stub_tool", result: ToolResult) {
            self.name = name
            self.result = result
        }
        func execute(arguments: [String: Any]) async throws -> ToolResult { result }
    }

    /// A thread-safe collector for events emitted by the adapter under test.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AgentEvent] = []
        func record(_ event: AgentEvent) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }
        var events: [AgentEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    @Test("call() emits .toolStart before and .toolEnd after, in order")
    func adapterEmitsStartThenEnd() async throws {
        let collector = EventCollector()
        let tool = StubTool(result: ToolResult(content: "3 results"))
        let adapter = try EventEmittingToolAdapter(wrapping: tool) { collector.record($0) }

        let output = try await adapter.call(arguments: GeneratedContent(properties: ["query": "x"]))
        #expect(output == "3 results")

        let events = collector.events
        #expect(events.count == 2)

        guard case .toolStart(let startName, let args) = events.first else {
            Issue.record("expected first event .toolStart, got \(String(describing: events.first))")
            return
        }
        #expect(startName == "stub_tool")
        // Arguments are surfaced as a JSON string of the GeneratedContent.
        #expect(args.contains("query"))

        guard case .toolEnd(let endName, let result) = events.last else {
            Issue.record("expected last event .toolEnd, got \(String(describing: events.last))")
            return
        }
        #expect(endName == "stub_tool")
        #expect(result.content == "3 results")
        #expect(result.isError == false)
    }

    @Test("An errored ToolResult is reflected in .toolEnd with isError true")
    func adapterFlagsErrorResult() async throws {
        let collector = EventCollector()
        let tool = StubTool(result: ToolResult(content: "no such note", isError: true))
        let adapter = try EventEmittingToolAdapter(wrapping: tool) { collector.record($0) }

        let output = try await adapter.call(arguments: GeneratedContent(properties: ["query": "x"]))
        // Base adapter prefixes errored content with "Error:".
        #expect(output == "Error: no such note")

        guard case .toolEnd(_, let result) = collector.events.last else {
            Issue.record("expected a .toolEnd event")
            return
        }
        #expect(result.isError == true)
    }

    @Test("Adapter mirrors the wrapped tool's name, description, and schema")
    func adapterMirrorsMetadata() throws {
        let tool = StubTool(name: "vault_search", result: ToolResult(content: "ok"))
        let adapter = try EventEmittingToolAdapter(wrapping: tool) { _ in }
        #expect(adapter.name == "vault_search")
        #expect(adapter.description == "stub")
        // Schema is built from the wrapped tool's parameter schema (delegated to M1).
        let data = try JSONEncoder().encode(adapter.parameters)
        #expect(!data.isEmpty)
    }

    // MARK: - Agentic loop (multi-round `respond`)

    @Test("Loop: a tool round then an answer round fires tool events and emits the final answer")
    func multiRoundAgenticLoop() async throws {
        let stub = StubTool(name: "vault_search", result: ToolResult(content: "found 3 notes"))
        let model = RoundScriptedLanguageModel(rounds: [
            .callTool(name: "vault_search"),
            .answer("Here are your notes."),
        ])
        let runner = SessionAgentRunner(model: model, instructions: "sys", tools: [stub])

        var events: [AgentEvent] = []
        for try await event in await runner.run(prompt: "find my notes") {
            events.append(event)
        }

        let firedStart = events.contains { if case .toolStart(let n, _) = $0 { return n == "vault_search" } else { return false } }
        let firedEnd = events.contains { if case .toolEnd(let n, _) = $0 { return n == "vault_search" } else { return false } }
        #expect(firedStart, "tool round should emit .toolStart")
        #expect(firedEnd, "tool round should emit .toolEnd")

        let answered = events.contains { if case .textToken(let t) = $0 { return t == "Here are your notes." } else { return false } }
        #expect(answered, "the answer round's text should be emitted")

        guard case .done(let final)? = events.last(where: { if case .done = $0 { return true } else { return false } }) else {
            Issue.record("expected a terminal .done event"); return
        }
        #expect(final == "Here are your notes.")

        // Tool round must precede the answer (search → synthesize).
        let startIdx = events.firstIndex { if case .toolStart = $0 { return true } else { return false } }
        let textIdx = events.firstIndex { if case .textToken = $0 { return true } else { return false } }
        #expect(startIdx != nil && textIdx != nil && startIdx! < textIdx!)
    }

    @Test("Loop: a direct answer with no tools emits once and finishes")
    func directAnswerNoTools() async throws {
        let model = RoundScriptedLanguageModel(rounds: [.answer("42")])
        let runner = SessionAgentRunner(model: model, instructions: "sys", tools: [])
        var texts: [String] = []
        var sawTool = false
        for try await event in await runner.run(prompt: "q") {
            if case .textToken(let t) = event { texts.append(t) }
            if case .toolStart = event { sawTool = true }
        }
        #expect(sawTool == false)
        #expect(texts == ["42"])
    }

    @Test("Loop folds instructions + prior tool results into each round's prompt")
    func roundPromptsCarryContextAndToolResults() async throws {
        let stub = StubTool(name: "vault_search", result: ToolResult(content: "RESULT-MARKER-42"))
        let recorder = PromptRecorder()
        let model = RoundScriptedLanguageModel(
            rounds: [.callTool(name: "vault_search"), .answer("done")],
            recorder: recorder
        )
        let runner = SessionAgentRunner(model: model, instructions: "SYS-CONTEXT-XYZ", tools: [stub])
        for try await _ in await runner.run(prompt: "find my notes") {}

        let prompts = recorder.snapshot()
        #expect(prompts.count >= 2)
        // Round 0: instructions + user request, before any tool results exist.
        #expect(prompts[0].contains("SYS-CONTEXT-XYZ"))
        #expect(prompts[0].contains("find my notes"))
        // Round 1: the prior tool's output is threaded forward — the stateless
        // backend would otherwise lose it (the bug this guards against).
        #expect(prompts[1].contains("RESULT-MARKER-42"))
    }

    @Test("roundPrompt composes context, request, results; forceAnswer suppresses tools")
    func roundPromptComposition() {
        let withResults = SessionAgentRunner.roundPrompt(
            instructions: "CTX",
            userRequest: "Q",
            toolResults: [.init(name: "vault_search", output: "OUT")],
            forceAnswer: false
        )
        #expect(withResults.contains("CTX"))
        #expect(withResults.contains("Q"))
        #expect(withResults.contains("vault_search"))
        #expect(withResults.contains("OUT"))

        let forced = SessionAgentRunner.roundPrompt(
            instructions: "", userRequest: "Q", toolResults: [], forceAnswer: true
        )
        #expect(forced.localizedCaseInsensitiveContains("do not call"))
    }

    @Test("roundOutcome: text is final only when the round ran no tools (PUNK-dpl)")
    func roundOutcomeRule() {
        #expect(SessionAgentRunner.roundOutcome(text: "The answer.", ranTools: false) == .finalAnswer)
        #expect(SessionAgentRunner.roundOutcome(text: "Let me read X first.", ranTools: true) == .narration)
        #expect(SessionAgentRunner.roundOutcome(text: "", ranTools: true) == .toolsOnly)
        #expect(SessionAgentRunner.roundOutcome(text: "", ranTools: false) == .toolsOnly)
    }

    @Test("roundPrompt folds narration forward and marks it already shown")
    func roundPromptNarration() {
        let prompt = SessionAgentRunner.roundPrompt(
            instructions: "CTX",
            userRequest: "Q",
            toolResults: [.init(name: "vault_search", output: "OUT")],
            narrations: ["Let me search the vault first."],
            forceAnswer: false
        )
        #expect(prompt.contains("Let me search the vault first."))
        #expect(prompt.contains("working notes from earlier rounds"))
        #expect(prompt.contains("don't repeat them"))

        let without = SessionAgentRunner.roundPrompt(
            instructions: "CTX", userRequest: "Q", toolResults: [], forceAnswer: false
        )
        #expect(!without.contains("working notes"))
    }
}

// MARK: - Round-based scripted model (Ollama-faithful: one model round per `respond`)

/// A deterministic, no-network model whose `respond` returns ONE round at a time —
/// faithful to `OllamaLanguageModel`, where a tool-call turn yields empty content
/// (and fires the tools) and a later turn yields the final text. This exercises
/// `SessionAgentRunner`'s real multi-round loop, unlike the eval-package
/// `ScriptedLanguageModel` which plays its whole script in a single call.
private struct RoundScriptedLanguageModel: AnyLanguageModel.LanguageModel {
    typealias UnavailableReason = Never

    enum Round: Sendable {
        case callTool(name: String)
        case answer(String)
    }

    let rounds: [Round]
    var recorder: PromptRecorder?
    private let cursor = RoundCursor()

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        recorder?.record(prompt.description)
        let index = await cursor.next()
        let round = rounds[min(index, rounds.count - 1)]
        switch round {
        case let .callTool(name):
            if let tool = session.tools.first(where: { $0.name == name }) {
                let args = GeneratedContent(
                    kind: .structure(properties: ["query": GeneratedContent("notes")], orderedKeys: ["query"])
                )
                try await invokeSessionTool(tool, with: args)
            }
            // Empty content => the runner treats this as a tool-only round and continues.
            return try Self.response("", as: type)
        case let .answer(text):
            return try Self.response(text, as: type)
        }
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        // The loop uses `respond`, not streaming; a trivial empty stream suffices.
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { $0.finish() }
        return LanguageModelSession.ResponseStream(stream: stream)
    }

    private static func response<Content>(
        _ text: String,
        as type: Content.Type
    ) throws -> LanguageModelSession.Response<Content> where Content: Generable {
        if let content = text as? Content {
            return LanguageModelSession.Response(content: content, rawContent: GeneratedContent(text), transcriptEntries: [])
        }
        let generated = GeneratedContent(text)
        return LanguageModelSession.Response(content: try type.init(generated), rawContent: generated, transcriptEntries: [])
    }
}

/// Serializes the round counter across `respond` calls (the session shares one
/// boxed model instance, so the actor reference is shared across copies).
private actor RoundCursor {
    private var index = 0
    func next() -> Int { defer { index += 1 }; return index }
}

/// Thread-safe recorder of the prompt text the model received on each round.
private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    func record(_ prompt: String) {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }
}

/// Open an `any Tool` existential to call it with `GeneratedContent` arguments
/// (every session tool here is built by `SessionAgentRunner`, pinning
/// `Arguments == GeneratedContent`).
private func invokeSessionTool<T: AnyLanguageModel.Tool>(_ tool: T, with arguments: GeneratedContent) async throws {
    guard let typed = arguments as? T.Arguments else { return }
    _ = try await tool.call(arguments: typed)
}
