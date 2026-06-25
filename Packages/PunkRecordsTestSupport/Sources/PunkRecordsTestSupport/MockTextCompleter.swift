import Foundation
import PunkRecordsCore

/// Deterministic ``TextCompleter`` for tests: returns scripted responses in order
/// and records every prompt it was asked to complete.
///
/// Pure Core dependency — no network, no AnyLanguageModel — so it drives
/// ``NoteCompiler`` tests without the orchestrator/provider stack. When the
/// scripted responses run out it falls back to a fixed marker string.
public actor MockTextCompleter: TextCompleter {
    public private(set) var responses: [String]
    public private(set) var prompts: [String] = []

    public init(responses: [String]) {
        self.responses = responses
    }

    /// Convenience for the common single-response case.
    public init(response: String) {
        self.responses = [response]
    }

    public func complete(prompt: String) async throws -> String {
        prompts.append(prompt)
        guard !responses.isEmpty else { return "Script exhausted" }
        return responses.removeFirst()
    }
}
