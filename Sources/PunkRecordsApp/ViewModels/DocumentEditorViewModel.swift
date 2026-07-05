import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Owns one open note's editing state and its autosave + crash-recovery policy.
///
/// The view (`RawEditorView`/its `NSTextView` coordinator) stays a thin shell:
/// it forwards keystrokes to ``updateContent(_:)`` and lets this view model
/// decide *when* to persist. Timing decisions are pure and unit-tested in
/// `AutosaveScheduler`; the crash-recovery sidecar I/O lives behind the Core
/// `CrashRecoveryStore` seam (Infra's `FileSystemCrashRecoveryStore`).
///
/// Lifecycle of an edit:
///   1. ``updateContent(_:)`` marks the note dirty, stamps `lastEditTime`, and
///      (re)schedules the autosave task.
///   2. The autosave task first writes a recovery sidecar with the current
///      content (so a crash before the real save is recoverable), then sleeps
///      until `AutosaveScheduler.fireDeadline` — the earlier of "1.5s after the
///      last edit" and "30s after the last durable save".
///   3. On a successful real save the sidecar is removed and the note is clean.
@MainActor
@Observable
final class DocumentEditorViewModel {
    var document: Document
    var isDirty = false
    var selectionRange: NSRange?
    var isSaving = false

    private let repository: FileSystemDocumentRepository
    private let searchIndex: SQLiteSearchIndex?
    private let recoveryStore: (any CrashRecoveryStore)?
    private let canonicalParser = CanonicalMarkdownParser()

    /// When the most recent edit landed (drives the debounce).
    private var lastEditTime = Date()
    /// When the note was last durably written (drives the 30s periodic backstop).
    /// Seeded at open so the first periodic deadline is measured from load.
    private var lastSaveTime = Date()
    /// The single in-flight autosave task, cancelled + replaced on each edit.
    private var autosaveTask: Task<Void, Never>?

    init(
        document: Document,
        repository: FileSystemDocumentRepository,
        searchIndex: SQLiteSearchIndex?,
        recoveryStore: (any CrashRecoveryStore)? = nil
    ) {
        self.document = document
        self.repository = repository
        self.searchIndex = searchIndex
        self.recoveryStore = recoveryStore
    }

    // No `deinit` cancel: the autosave task captures `[weak self]` and no-ops
    // once this view model is gone (its `self?.recoveryStore` write is skipped
    // and the post-sleep `guard let self` bails), so a lingering task is inert.

    func updateContent(_ newContent: String) {
        guard newContent != document.content else { return }
        document = Document(
            id: document.id,
            title: document.title,
            content: newContent,
            path: document.path,
            tags: document.tags,
            created: document.created,
            modified: Date(),
            frontmatter: document.frontmatter,
            linkedDocumentIDs: document.linkedDocumentIDs
        )
        isDirty = true
        lastEditTime = Date()
        scheduleAutosave()
    }

    /// (Re)arm the autosave task. Each edit cancels the previous task and starts
    /// a fresh one so the debounce resets — but because the periodic deadline is
    /// anchored to `lastSaveTime` (which does *not* move while typing), it stays
    /// a fixed absolute time and still fires ~30s after the last save even under
    /// continuous typing. The task writes the recovery sidecar *eagerly* (before
    /// sleeping) so unsaved keystrokes are captured immediately.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshotID = document.id
        let snapshotContent = document.content
        autosaveTask = Task { [weak self] in
            // Capture the latest content for crash recovery right away.
            if let store = self?.recoveryStore {
                try? await store.writeSidecar(noteID: snapshotID, content: snapshotContent)
            }
            guard let self, !Task.isCancelled else { return }

            let delay = AutosaveScheduler.delayUntilFire(
                lastEditTime: self.lastEditTime,
                lastSaveTime: self.lastSaveTime,
                now: Date()
            )
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self.save()
        }
    }

    func save() async throws {
        guard isDirty else { return }
        // Snapshot what we're about to persist so a race with edits arriving
        // mid-save can't clear the dirty flag (or drop the sidecar) for content
        // that has since moved on.
        let snapshot = document
        isSaving = true
        defer { isSaving = false }

        // Canonical AST snapshot — feeds future export and Quick Look paths.
        _ = canonicalParser.parse(snapshot.content)

        try await repository.save(snapshot)

        if let index = searchIndex {
            try await index.index(document: snapshot)
        }

        lastSaveTime = Date()

        // Only settle to a clean state if no newer edit landed while we were
        // writing. If content moved on, a fresher sidecar already exists and a
        // follow-up autosave is scheduled — keep dirty set and the sidecar in
        // place so that work isn't lost.
        if document.content == snapshot.content {
            isDirty = false
            if let store = recoveryStore {
                try? await store.removeSidecar(noteID: snapshot.id)
            }
        }
    }
}
