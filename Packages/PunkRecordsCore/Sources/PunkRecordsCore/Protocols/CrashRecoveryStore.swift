import Foundation

/// Persists per-note crash-recovery sidecars so unsaved edits survive an app
/// crash or power loss between debounced saves. Core defines the seam; Infra
/// (`FileSystemCrashRecoveryStore`) provides the file-backed implementation.
///
/// Sidecars live at `{vault}/.punkrecords/recovery/{note-id}.md` (see
/// ``VaultPaths/recoverySidecarPath(forNoteID:)``). Writes use
/// write-then-atomic-rename semantics so a crash mid-write never leaves a
/// partial file — a reader either sees the previous complete sidecar or the new
/// complete one, never a torn blend.
///
/// Interaction with future iCloud Drive sync (PUNK-t4g): because every sidecar
/// (and every real note save) lands via an atomic rename rather than an
/// in-place rewrite, the sync daemon only ever observes complete files. That
/// closes most conflict windows — there is no moment where iCloud could upload
/// a half-written note — so recovery and sync compose without a partial-file
/// hazard. Sidecars live under `.punkrecords/`, which sync should exclude from
/// the shared note set; they are per-device local safety copies, not content.
public protocol CrashRecoveryStore: Actor {
    /// Write (or overwrite) the recovery sidecar for a note with its current,
    /// not-yet-durably-saved content. Atomic: never leaves a partial file.
    func writeSidecar(noteID: DocumentID, content: String) async throws

    /// Remove the recovery sidecar for a note. Called after a successful real
    /// save (the work is now in the note itself) or when the user declines a
    /// recovery prompt. A no-op if no sidecar exists.
    func removeSidecar(noteID: DocumentID) async throws

    /// Load every sidecar currently in the recovery directory. Entries whose
    /// filename is not a `{uuid}.md` sidecar (e.g. in-flight temp files) are
    /// skipped. Order is unspecified.
    func loadSidecars() async throws -> [RecoverySidecar]
}
