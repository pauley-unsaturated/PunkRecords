import Foundation

/// Persists chat conversations as ``ChatThread`` values. Core defines the seam;
/// Infra (`FileSystemThreadStore`) provides the file-backed implementation — one
/// JSON file per thread under `{vault}/.punkrecords/threads/`.
///
/// An actor so all vault I/O is serialized off the main actor, matching the
/// project's other storage seams (``CrashRecoveryStore``, `DocumentRepository`).
///
/// `summaries()` returns lightweight ``ThreadSummary`` rows for the thread
/// switcher and must not materialize full message bodies — the switcher only
/// needs id, title, updated-at, and a count.
public protocol ThreadStore: Actor {
    /// List every stored thread as a lightweight summary, without loading full
    /// message bodies. Order is unspecified; callers sort with
    /// ``ChatThreadHelpers/sortedSummaries(_:)``.
    func summaries() async throws -> [ThreadSummary]

    /// Load the full thread with the given id, or `nil` if none is stored.
    func load(id: UUID) async throws -> ChatThread?

    /// Write (or overwrite) a thread. Atomic: never leaves a partial file.
    func save(_ thread: ChatThread) async throws

    /// Delete the thread with the given id. A no-op if it does not exist.
    func delete(id: UUID) async throws
}
