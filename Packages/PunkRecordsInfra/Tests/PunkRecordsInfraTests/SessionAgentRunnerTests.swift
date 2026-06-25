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
}
