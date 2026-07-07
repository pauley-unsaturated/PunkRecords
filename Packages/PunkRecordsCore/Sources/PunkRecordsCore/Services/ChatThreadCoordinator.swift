import Foundation
import Observation

/// A wired ``ThreadStore`` plus its optional per-thread ``ThreadVectorSource``,
/// produced by the coordinator's injected store factory. In the app both are the
/// SAME object — the embedding-indexing decorator wrapping the file store — so
/// `read_thread` can read cached per-thread vectors off the store it persists to.
public struct WiredThreadStore: Sendable {
    public let store: any ThreadStore
    public let vectorSource: (any ThreadVectorSource)?

    public init(store: any ThreadStore, vectorSource: (any ThreadVectorSource)? = nil) {
        self.store = store
        self.vectorSource = vectorSource
    }
}

/// Owns the chat thread lifecycle lifted out of the App-layer `ChatSessionController`:
/// on-demand store wiring, the persist / new / switch / delete / fork ORDERING
/// (persist-before-clear), and the thread-summaries refresh.
///
/// Extracted into Core so the data-loss-adjacent ordering rules (PUNK-hdd,
/// PUNK-b51) are unit-testable with a mock ``ThreadStore`` — the controller has no
/// unit bundle, and app-hosted test bundles break the SPM build graph. Everything
/// App/Infra/AppKit-specific is injected as a closure, so Core owns none of it:
/// - `storeFactory` builds+wires the store for the current vault (file store +
///   legacy migration + embedding decorator live App-side).
/// - `focusNote` resolves the note a conversation is about against the live vault.
/// - `reportError` surfaces a save/delete/fork failure to the user.
///
/// `@MainActor @Observable`: the controller forwards its `messages` /
/// `activeThread` / `threadSummaries` to this coordinator, so SwiftUI observes the
/// coordinator's stored state transitively through those forwards.
@MainActor
@Observable
public final class ChatThreadCoordinator {
    /// The conversation currently shown. ``messages`` mirrors its contents; the
    /// thread is persisted after each turn. `nil` only before the first
    /// ``loadInitialThread()``.
    public private(set) var activeThread: ChatThread?

    /// Lightweight rows for the thread switcher, sorted newest-first. Refreshed
    /// after every save/delete.
    public private(set) var threadSummaries: [ThreadSummary] = []

    /// The live transcript. Mirrors ``activeThread``'s messages; mutated directly
    /// by the controller's send pipeline / reducer, then persisted.
    public var messages: [ChatMessage] = []

    /// Resolved lazily from the current vault by ``ensureStore()``. In the app this
    /// is the embedding-indexing decorator wrapping the file store, so every
    /// persisted thread gets an on-device embedding for `read_thread`'s semantic mode.
    public private(set) var threadStore: (any ThreadStore)?

    /// The same object as ``threadStore``, surfaced as its ``ThreadVectorSource`` so
    /// `read_thread` can read cached per-thread vectors. `nil` until wired.
    public private(set) var threadVectorSource: (any ThreadVectorSource)?

    /// In-flight one-time store wiring (see ``ensureStore()``). Because the
    /// controller is shared, the sidebar, the chat panel, and any persist call may
    /// race to wire the store on first use; concurrent callers await this task so
    /// every entry point observes a wired store instead of skipping silently
    /// (skipping is how PUNK-hdd lost a conversation).
    @ObservationIgnored private var storeWiringTask: Task<Void, Never>?

    @ObservationIgnored private let storeFactory: @MainActor () async -> WiredThreadStore?
    @ObservationIgnored private let focusNote: @MainActor ([ChatMessage]) -> ThreadFocusNote?
    @ObservationIgnored private let reportError: @MainActor (String) -> Void

    public init(
        storeFactory: @escaping @MainActor () async -> WiredThreadStore?,
        focusNote: @escaping @MainActor ([ChatMessage]) -> ThreadFocusNote? = { _ in nil },
        reportError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.storeFactory = storeFactory
        self.focusNote = focusNote
        self.reportError = reportError
    }

    // MARK: - Thread lifecycle

    /// First-open setup for the panel: wire the store, load the switcher list, and
    /// activate the most recent thread (or start a fresh empty one). Idempotent —
    /// safe to call from `.task`, which may re-run on reappearance, and on a
    /// same-vault reopen it keeps the already-wired store + active thread rather
    /// than clobbering them (PUNK-hdd).
    public func loadInitialThread() async {
        await ensureStore()
        guard let store = threadStore else { return }

        await refreshSummaries()

        // Already showing a thread (e.g. the sidebar activated one first) — don't
        // clobber it.
        guard activeThread == nil else { return }

        if let newest = threadSummaries.first,
           let loaded = try? await store.load(id: newest.id) {
            activate(loaded)
        } else {
            startFreshThread()
        }
    }

    /// Wire the thread store for the current vault if it isn't already. Every
    /// thread-lifecycle entry point calls this, so a coordinator whose views'
    /// `.task`s already fired still wires itself before touching disk instead of
    /// silently dropping saves (PUNK-hdd). Concurrent callers await the same wiring
    /// task. A `nil` factory result (e.g. no vault) leaves the store unwired and a
    /// later call retries.
    private func ensureStore() async {
        if threadStore != nil { return }
        if let inFlight = storeWiringTask {
            await inFlight.value
            return
        }

        let wiring = Task { @MainActor in
            guard let wired = await self.storeFactory() else { return }
            self.threadStore = wired.store
            self.threadVectorSource = wired.vectorSource
        }
        storeWiringTask = wiring
        await wiring.value
        storeWiringTask = nil
    }

    /// Start a new, empty conversation, persisting the current one FIRST and
    /// refusing to clear if that save did not land — clearing must never destroy
    /// the only copy of a chat (PUNK-hdd, PUNK-b51). The fresh thread stays in
    /// memory until it has content, so unused "New Chat" presses never clutter the
    /// switcher. Also serves as the "clear" affordance.
    public func newChat() async {
        guard await persistActiveThread() else { return }
        startFreshThread()
    }

    /// Switch to a stored thread, loading its messages into the transcript.
    /// Persists the outgoing conversation first and refuses to switch when that
    /// save fails (same rule as ``newChat()``); a no-op for unloadable ids.
    public func switchTo(threadID: UUID) async {
        guard await persistActiveThread() else { return }
        guard let store = threadStore else { return }
        guard let loaded = try? await store.load(id: threadID) else { return }
        activate(loaded)
    }

    /// Delete a thread. If it was the active one, fall back to the next most
    /// recent thread, or a fresh empty one when none remain.
    public func deleteThread(id: UUID) async {
        await ensureStore()
        guard let store = threadStore else { return }
        do {
            try await store.delete(id: id)
        } catch {
            reportError("Failed to delete chat: \(error.localizedDescription)")
            return
        }
        await refreshSummaries()

        guard activeThread?.id == id else { return }
        if let newest = threadSummaries.first,
           let loaded = try? await store.load(id: newest.id) {
            activate(loaded)
        } else {
            startFreshThread()
        }
    }

    /// Fork the active conversation at `messageID`: create a new thread holding the
    /// transcript up to AND INCLUDING that message, with lineage back to the active
    /// thread, then persist it and switch to it. The original thread is left
    /// untouched (already on disk from its own turns). A no-op when there is no
    /// active thread/store or the id isn't in the current transcript.
    ///
    /// Forks over the live ``messages`` (not `activeThread.messages`) so an unsaved
    /// streaming tail is captured, and so the branch matches exactly what the user
    /// sees on screen.
    public func forkThread(at messageID: UUID) async {
        await ensureStore()
        guard let store = threadStore, let source = activeThread else { return }
        var forkSource = source
        forkSource.messages = messages
        guard let fork = ChatThreadHelpers.fork(forkSource, atMessageID: messageID) else { return }
        do {
            try await store.save(fork)
        } catch {
            reportError("Failed to fork chat: \(error.localizedDescription)")
            return
        }
        activate(fork)
        await refreshSummaries()
    }

    /// Persist the active thread's current messages. Skips empty conversations so a
    /// brand-new thread only lands on disk once it has content. Re-derives the
    /// title and bumps `updatedAt`, then refreshes the switcher. Wires the store on
    /// demand and surfaces a visible error rather than silently dropping a
    /// conversation (PUNK-hdd). Returns `false` when there were messages to save and
    /// the save did not land — callers about to clear/replace the transcript must
    /// treat that as "do not discard" (PUNK-b51).
    @discardableResult
    public func persistActiveThread() async -> Bool {
        guard !messages.isEmpty else { return true }
        await ensureStore()
        guard let store = threadStore else {
            reportError("Chat could not be saved — no vault is open.")
            return false
        }
        var thread = activeThread ?? ChatThread()
        // The focus note is resolved App-side (it needs the live vault); the
        // coordinator only threads it onto the saved thread.
        thread.update(messages: messages, focusNote: focusNote(messages))
        activeThread = thread
        do {
            try await store.save(thread)
        } catch {
            reportError("Failed to save chat: \(error.localizedDescription)")
            return false
        }
        await refreshSummaries()
        return true
    }

    /// Vault-relative paths of notes that `create_note` calls in the turns AFTER
    /// `messageID` created — the side effects a rewind TO `messageID` would
    /// leave behind (rewinding never deletes them). Meant to be called BEFORE
    /// ``rewind(to:)`` so a confirmation dialog can list what will be kept.
    /// Empty when `messageID` isn't in the live transcript, is the last message
    /// (nothing would be removed), or no removed turn created a note.
    public func sideEffectNotePaths(afterRewindTo messageID: UUID) -> [String] {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              index + 1 < messages.count else { return [] }
        return ChatThreadHelpers.createdNotePaths(in: Array(messages[(index + 1)...]))
    }

    /// Rewind the active conversation to `messageID`: keep the transcript up to
    /// and including that message, drop everything after, and persist the
    /// truncation IMMEDIATELY (PUNK-xzw) — so a crash right after a rewind can't
    /// resurrect the removed tail. Side effects from the removed turns (e.g.
    /// notes created via `create_note`) are intentionally left in the vault —
    /// see ``sideEffectNotePaths(afterRewindTo:)`` for what a confirmation
    /// dialog should warn about BEFORE calling this.
    ///
    /// A no-op (returns `true`, nothing changes) when `messageID` isn't in the
    /// live transcript. On save failure, ROLLS BACK the in-memory transcript to
    /// its pre-rewind contents and reports the error — same discipline as
    /// `newChat`'s persist-before-clear rule (PUNK-b51): the UI must never keep
    /// showing a truncated transcript that didn't actually make it to disk.
    @discardableResult
    public func rewind(to messageID: UUID) async -> Bool {
        guard let truncated = ChatThreadHelpers.rewind(messages, to: messageID) else { return true }

        await ensureStore()
        guard let store = threadStore else {
            reportError("Chat could not be saved — no vault is open.")
            return false
        }

        let originalMessages = messages
        let originalThread = activeThread

        messages = truncated
        var thread = activeThread ?? ChatThread()
        thread.update(messages: truncated, focusNote: focusNote(truncated))
        activeThread = thread

        do {
            try await store.save(thread)
        } catch {
            // Roll back — the UI must never show a truncated transcript that
            // failed to reach disk while disk still holds the long one.
            messages = originalMessages
            activeThread = originalThread
            reportError("Failed to save chat: \(error.localizedDescription)")
            return false
        }
        await refreshSummaries()
        return true
    }

    private func activate(_ thread: ChatThread) {
        activeThread = thread
        messages = thread.messages
    }

    private func startFreshThread() {
        activeThread = ChatThread()
        messages = []
    }

    private func refreshSummaries() async {
        guard let store = threadStore else { return }
        let loaded = (try? await store.summaries()) ?? []
        threadSummaries = ChatThreadHelpers.sortedSummaries(loaded)
    }
}
