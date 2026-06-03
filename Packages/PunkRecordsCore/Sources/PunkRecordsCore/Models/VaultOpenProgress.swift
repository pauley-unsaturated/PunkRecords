import Foundation

/// Progress of a vault open, surfaced to the UI so a long ingest doesn't look
/// like a frozen window.
///
/// The two phases mirror the two slow steps of opening a vault: reading and
/// parsing every note off disk, then building the full-text search index.
/// `label` and `fractionCompleted` are pure derivations kept here (rather than
/// inline in the SwiftUI overlay) so they can be unit-tested.
public struct VaultOpenProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Reading + parsing notes from disk. No total is known up front (the
        /// directory is streamed lazily), so this phase is indeterminate.
        case reading(notesRead: Int)
        /// Building the search index — `completed` of `total` notes indexed.
        case indexing(completed: Int, total: Int)
    }

    public var phase: Phase

    public init(phase: Phase) {
        self.phase = phase
    }

    /// Status line shown beneath the progress indicator.
    public var label: String {
        switch phase {
        case .reading(let notesRead):
            return notesRead > 0 ? "Reading notes… (\(notesRead))" : "Reading notes…"
        case .indexing(let completed, let total):
            guard total > 0 else { return "Indexing notes…" }
            return "Indexing notes… (\(completed) of \(total))"
        }
    }

    /// Determinate fraction in `0...1`, or `nil` when the phase is
    /// indeterminate — the UI shows a spinning indicator for `nil` and a
    /// filling bar otherwise.
    public var fractionCompleted: Double? {
        switch phase {
        case .reading:
            return nil
        case .indexing(let completed, let total):
            guard total > 0 else { return nil }
            let clamped = min(max(completed, 0), total)
            return Double(clamped) / Double(total)
        }
    }
}
