import Foundation

/// A crash-recovery sidecar found on disk: the unsaved content captured for one
/// note, plus the sidecar file's modification time. Produced by the Infra
/// `CrashRecoveryStore`; consumed by the pure ``RecoveryScan``.
public struct RecoverySidecar: Sendable, Equatable {
    public let noteID: DocumentID
    public let content: String
    public let modified: Date

    public init(noteID: DocumentID, content: String, modified: Date) {
        self.noteID = noteID
        self.content = content
        self.modified = modified
    }
}

/// The on-disk state of a note a sidecar might belong to. Assembled from the
/// repository's loaded documents so the scan can decide whether a sidecar holds
/// genuinely newer, unsaved work.
public struct RecoveryNoteState: Sendable, Equatable {
    public let content: String
    public let modified: Date

    public init(content: String, modified: Date) {
        self.content = content
        self.modified = modified
    }
}

/// A sidecar that represents recoverable unsaved work, surfaced to the user.
public struct RecoveryCandidate: Sendable, Equatable, Identifiable {
    public let noteID: DocumentID
    /// The unsaved content from the sidecar, to restore into the note.
    public let recoveredContent: String
    /// Whether the target note is still present on disk. `false` means the note
    /// itself was lost (recovering re-creates its content); surfaced so the UI
    /// can word the prompt appropriately.
    public let noteExistsOnDisk: Bool

    public init(noteID: DocumentID, recoveredContent: String, noteExistsOnDisk: Bool) {
        self.noteID = noteID
        self.recoveredContent = recoveredContent
        self.noteExistsOnDisk = noteExistsOnDisk
    }

    public var id: DocumentID { noteID }
}

/// The outcome of comparing every discovered sidecar against its note.
public struct RecoveryScanResult: Sendable, Equatable {
    /// Sidecars holding unsaved work worth prompting the user to recover.
    public let recoverable: [RecoveryCandidate]
    /// Note ids whose sidecar is stale (note already matches or supersedes it)
    /// and can be deleted silently — no data would be lost.
    public let stale: [DocumentID]

    public init(recoverable: [RecoveryCandidate], stale: [DocumentID]) {
        self.recoverable = recoverable
        self.stale = stale
    }
}

/// Pure crash-recovery decision logic. Given the sidecars found on disk and the
/// current state of the notes they belong to, classifies each sidecar as either
/// recoverable (prompt the user) or stale (safe to discard). Lives in Core so
/// the policy is unit-tested without touching the file system.
///
/// A sidecar is **recoverable** when it captures work not already on disk:
///   - the target note is missing entirely (the note may have been lost), or
///   - the sidecar is newer than the note *and* its content differs.
///
/// A sidecar is **stale** when the note already reflects it — the content
/// matches, or the note on disk is at least as new as the sidecar. Stale
/// sidecars are leftovers from a clean save whose removal was interrupted and
/// carry no unsaved work, so they are dropped without prompting.
public enum RecoveryScan {
    public static func scan(
        sidecars: [RecoverySidecar],
        notes: [DocumentID: RecoveryNoteState]
    ) -> RecoveryScanResult {
        var recoverable: [RecoveryCandidate] = []
        var stale: [DocumentID] = []

        for sidecar in sidecars {
            guard let note = notes[sidecar.noteID] else {
                // No matching note on disk — treat as recoverable so genuinely
                // lost work isn't silently discarded.
                recoverable.append(
                    RecoveryCandidate(
                        noteID: sidecar.noteID,
                        recoveredContent: sidecar.content,
                        noteExistsOnDisk: false
                    )
                )
                continue
            }

            // Already persisted: identical content means a real save happened;
            // the sidecar is just an un-removed leftover.
            if sidecar.content == note.content {
                stale.append(sidecar.noteID)
                continue
            }

            // Content differs — only recover if the sidecar is strictly newer
            // than the note on disk. A note newer than the sidecar means the
            // user (or a sync) saved more recent content; honor the note.
            if sidecar.modified > note.modified {
                recoverable.append(
                    RecoveryCandidate(
                        noteID: sidecar.noteID,
                        recoveredContent: sidecar.content,
                        noteExistsOnDisk: true
                    )
                )
            } else {
                stale.append(sidecar.noteID)
            }
        }

        return RecoveryScanResult(recoverable: recoverable, stale: stale)
    }
}
