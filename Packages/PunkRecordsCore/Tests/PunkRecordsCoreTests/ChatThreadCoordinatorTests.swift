import Foundation
import Testing
@testable import PunkRecordsCore

/// Regression coverage for the chat thread-lifecycle ORDERING extracted from the
/// App-layer `ChatSessionController` into ``ChatThreadCoordinator`` (PUNK-ozb).
/// These lock down the PUNK-hdd / PUNK-b51 data-loss fixes — on-demand store
/// wiring, persist-before-clear, wired-store reuse, and "New Chat never
/// overwrites the previous session" — on the real coordinator path with an
/// in-memory ``ThreadStore``, so they run under `swift test` without the app module.
@MainActor
@Suite("ChatThreadCoordinator lifecycle (PUNK-hdd / PUNK-b51 regressions)")
struct ChatThreadCoordinatorTests {

    // MARK: - Test doubles

    /// In-memory ``ThreadStore`` that counts saves and can be armed to throw on the
    /// next save, so tests can assert on persistence AND exercise the
    /// persist-before-clear guard when a save fails.
    actor RecordingThreadStore: ThreadStore {
        private(set) var stored: [UUID: ChatThread] = [:]
        private(set) var saveCount = 0
        private var failNextSave = false

        struct StoreError: Error {}

        init(_ threads: [ChatThread] = []) {
            for thread in threads { stored[thread.id] = thread }
        }

        func armNextSaveFailure() { failNextSave = true }

        func summaries() async throws -> [ThreadSummary] { stored.values.map(\.summary) }
        func load(id: UUID) async throws -> ChatThread? { stored[id] }

        func save(_ thread: ChatThread) async throws {
            if failNextSave {
                failNextSave = false
                throw StoreError()
            }
            saveCount += 1
            stored[thread.id] = thread
        }

        func delete(id: UUID) async throws { stored[id] = nil }
    }

    /// Owns the shared store, counts store-factory invocations (so tests can assert
    /// the store is wired at most once), and collects surfaced error messages.
    @MainActor
    final class Harness {
        let store: RecordingThreadStore
        private(set) var factoryCallCount = 0
        var factoryReturnsNil = false
        var focusNoteResult: ThreadFocusNote?
        private(set) var errors: [String] = []

        /// Seeds go through the actor's synchronous initializer (NOT `save()`), so
        /// they are present without a race AND don't inflate the save counters.
        init(seeded: [ChatThread] = []) {
            store = RecordingThreadStore(seeded)
        }

        func makeCoordinator() -> ChatThreadCoordinator {
            ChatThreadCoordinator(
                storeFactory: { [self] in
                    factoryCallCount += 1
                    if factoryReturnsNil { return nil }
                    return WiredThreadStore(store: store, vectorSource: nil)
                },
                focusNote: { [self] _ in focusNoteResult },
                reportError: { [self] message in errors.append(message) }
            )
        }
    }

    private func userMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    // MARK: - Scenario 1: persist wires the store on demand + list visibility

    @Test("persist wires the store on demand and the persisted thread appears in the summaries")
    func persistWiresStoreOnDemandAndLists() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        // Nothing is wired until the first thread-lifecycle call touches disk.
        #expect(coordinator.threadStore == nil)
        #expect(harness.factoryCallCount == 0)

        coordinator.messages = [userMessage("first question")]
        let saved = await coordinator.persistActiveThread()

        #expect(saved)
        #expect(harness.factoryCallCount == 1)          // wired lazily by persist
        #expect(coordinator.threadStore != nil)

        let stored = await harness.store.stored
        #expect(stored.count == 1)
        #expect(coordinator.activeThread != nil)
        #expect(stored.keys.contains(coordinator.activeThread!.id))

        // The persisted thread is visible in the switcher list.
        #expect(coordinator.threadSummaries.count == 1)
        #expect(coordinator.threadSummaries.first?.id == coordinator.activeThread?.id)
        #expect(coordinator.threadSummaries.first?.title == "first question")
    }

    // MARK: - Scenario 2: newChat persists BEFORE clearing

    @Test("newChat persists the current thread before clearing, and the fresh thread is a new id")
    func newChatPersistsBeforeClearing() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        coordinator.messages = [userMessage("keep me")]
        _ = await coordinator.persistActiveThread()
        let outgoingID = coordinator.activeThread!.id

        await coordinator.newChat()

        // Outgoing conversation is on disk with its content intact...
        let stored = await harness.store.stored
        #expect(stored[outgoingID]?.messages.map(\.content) == ["keep me"])
        // ...the transcript is cleared...
        #expect(coordinator.messages.isEmpty)
        // ...and the fresh thread is a DIFFERENT id (never overwrites the previous).
        #expect(coordinator.activeThread!.id != outgoingID)
    }

    @Test("newChat refuses to clear the transcript when the save fails (PUNK-hdd)")
    func newChatKeepsTranscriptWhenSaveFails() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        // Wire the store with a first successful save so the later failure is a
        // genuine SAVE failure (not the "no store"/"no vault" branch).
        coordinator.messages = [userMessage("unsaved work")]
        _ = await coordinator.persistActiveThread()

        // A new turn lands, then the next save fails.
        coordinator.messages = [userMessage("unsaved work"), ChatMessage(role: .assistant, content: "reply")]
        await harness.store.armNextSaveFailure()

        await coordinator.newChat()

        // The failed save must NOT have discarded the transcript.
        #expect(coordinator.messages.count == 2)
        #expect(!harness.errors.isEmpty)                 // failure surfaced, not silent
    }

    @Test("persist with no store surfaces an error and reports failure (PUNK-hdd)")
    func persistWithoutStoreReportsFailure() async {
        let harness = Harness()
        harness.factoryReturnsNil = true                 // e.g. no vault open
        let coordinator = harness.makeCoordinator()

        coordinator.messages = [userMessage("cannot save this")]
        let saved = await coordinator.persistActiveThread()

        #expect(!saved)                                  // callers must not discard
        #expect(!harness.errors.isEmpty)
    }

    // MARK: - Scenario 3: same-vault reopen keeps the wired coordinator

    @Test("a second loadInitialThread reuses the wired store and keeps the active thread")
    func reopenKeepsWiredCoordinator() async {
        let seeded = ChatThread(messages: [userMessage("seeded conversation")])
        let harness = Harness(seeded: [seeded])
        let coordinator = harness.makeCoordinator()

        await coordinator.loadInitialThread()
        #expect(harness.factoryCallCount == 1)
        #expect(coordinator.activeThread?.id == seeded.id)

        // Simulate the panel's `.task` re-firing on a same-vault reopen: the store
        // is NOT rebuilt and the active thread is NOT clobbered.
        await coordinator.loadInitialThread()
        #expect(harness.factoryCallCount == 1)           // store wired exactly once
        #expect(coordinator.activeThread?.id == seeded.id)
    }

    // MARK: - Scenario 4: N newChat cycles → N distinct persisted threads (PUNK-b51)

    @Test("sequential newChat cycles each persist a distinct thread — the + button never overwrites (PUNK-b51)")
    func sequentialNewChatCyclesProduceDistinctThreads() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let cycles = 4
        for index in 0..<cycles {
            coordinator.messages = [userMessage("conversation \(index)")]
            await coordinator.newChat()
        }

        let stored = await harness.store.stored
        // N cycles ⇒ N stored threads with N distinct ids, one save each.
        #expect(stored.count == cycles)
        #expect(Set(stored.keys).count == cycles)
        #expect(await harness.store.saveCount == cycles)
        // Each cycle's content survived on its own thread (none overwrote another).
        let bodies = Set(stored.values.compactMap { $0.messages.first?.content })
        #expect(bodies == Set((0..<cycles).map { "conversation \($0)" }))
    }

    // MARK: - Delete / fork ordering (round out the extracted surface)

    @Test("deleting the active thread falls back to the next most recent")
    func deleteActiveFallsBackToNextRecent() async {
        let older = ChatThread(
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [userMessage("older")]
        )
        let newer = ChatThread(
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [userMessage("newer")]
        )
        let harness = Harness(seeded: [older, newer])
        let coordinator = harness.makeCoordinator()

        await coordinator.loadInitialThread()
        #expect(coordinator.activeThread?.id == newer.id)   // newest activated

        await coordinator.deleteThread(id: newer.id)

        // Deleted the active thread ⇒ fall back to the remaining (older) one.
        #expect(coordinator.activeThread?.id == older.id)
        let stored = await harness.store.stored
        #expect(stored[newer.id] == nil)
        #expect(coordinator.threadSummaries.map(\.id) == [older.id])
    }

    @Test("fork saves a new lineage-carrying thread and switches to it, leaving the source on disk")
    func forkCreatesLineageThreadAndSwitches() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let m1 = userMessage("root question")
        let m2 = ChatMessage(role: .assistant, content: "root answer")
        coordinator.messages = [m1, m2]
        _ = await coordinator.persistActiveThread()
        let sourceID = coordinator.activeThread!.id

        await coordinator.forkThread(at: m1.id)

        // Now showing the fork (a different thread) with lineage back to the source.
        #expect(coordinator.activeThread?.id != sourceID)
        #expect(coordinator.activeThread?.parentThreadID == sourceID)
        #expect(coordinator.activeThread?.forkedAtMessageID == m1.id)
        // The fork holds messages up to and including the fork point.
        #expect(coordinator.messages.map(\.content) == ["root question"])
        // Both the source and the fork are on disk.
        let stored = await harness.store.stored
        #expect(stored[sourceID] != nil)
        #expect(stored[coordinator.activeThread!.id] != nil)
    }

    // MARK: - Rewind (PUNK-xzw)

    @Test("rewind truncates the live transcript and persists immediately")
    func rewindTruncatesAndPersists() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let m1 = userMessage("first question")
        let m2 = ChatMessage(role: .assistant, content: "first answer")
        let m3 = userMessage("second question")
        let m4 = ChatMessage(role: .assistant, content: "second answer")
        coordinator.messages = [m1, m2, m3, m4]
        _ = await coordinator.persistActiveThread()
        let threadID = coordinator.activeThread!.id
        let saveCountBeforeRewind = await harness.store.saveCount

        let rewound = await coordinator.rewind(to: m2.id)

        #expect(rewound)
        // Kept through m2, dropped m3/m4.
        #expect(coordinator.messages.map(\.id) == [m1.id, m2.id])
        // Same thread, not a fork — id unchanged.
        #expect(coordinator.activeThread?.id == threadID)
        // Persisted immediately: the stored copy on "disk" also reflects the
        // truncation (a crash right after rewind can't resurrect the tail).
        let stored = await harness.store.stored
        #expect(stored[threadID]?.messages.map(\.id) == [m1.id, m2.id])
        #expect(await harness.store.saveCount == saveCountBeforeRewind + 1)
    }

    @Test("rewind to an unknown message id is a no-op and does not touch the store")
    func rewindUnknownIDIsNoOp() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        coordinator.messages = [userMessage("only message")]
        _ = await coordinator.persistActiveThread()
        let saveCountBefore = await harness.store.saveCount

        let rewound = await coordinator.rewind(to: UUID())

        #expect(rewound)
        #expect(coordinator.messages.count == 1)
        #expect(await harness.store.saveCount == saveCountBefore)   // no extra save attempted
        #expect(harness.errors.isEmpty)
    }

    @Test("rewind rolls back the in-memory transcript and reports an error when the save fails (PUNK-b51)")
    func rewindRollsBackOnSaveFailure() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let m1 = userMessage("keep me")
        let m2 = ChatMessage(role: .assistant, content: "reply")
        let m3 = userMessage("would be dropped")
        coordinator.messages = [m1, m2, m3]
        _ = await coordinator.persistActiveThread()
        let threadID = coordinator.activeThread!.id

        await harness.store.armNextSaveFailure()
        let rewound = await coordinator.rewind(to: m2.id)

        #expect(!rewound)
        // In-memory transcript rolled back to its pre-rewind (full) contents —
        // the UI must never show a truncated transcript disk doesn't have.
        #expect(coordinator.messages.map(\.id) == [m1.id, m2.id, m3.id])
        #expect(!harness.errors.isEmpty)
        // Disk still holds the pre-rewind (full) thread — the failed save never landed.
        let stored = await harness.store.stored
        #expect(stored[threadID]?.messages.map(\.id) == [m1.id, m2.id, m3.id])
    }

    @Test("sideEffectNotePaths(afterRewindTo:) lists create_note paths from the turns that would be dropped")
    func sideEffectNotePathsListsDroppedCreateNoteCalls() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let m1 = userMessage("make some notes")
        let created = ChatMessage(
            role: .tool,
            content: "",
            toolCall: ToolCallInfo(
                name: "create_note",
                arguments: "{}",
                output: "Created note 'Filters' at dsp/Filters.md",
                isError: false,
                isInFlight: false
            )
        )
        let m3 = ChatMessage(role: .assistant, content: "Done.")
        coordinator.messages = [m1, created, m3]

        let paths = coordinator.sideEffectNotePaths(afterRewindTo: m1.id)

        #expect(paths == ["dsp/Filters.md"])
    }

    @Test("sideEffectNotePaths(afterRewindTo:) is empty when rewinding at the last message")
    func sideEffectNotePathsEmptyAtLastMessage() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()

        let m1 = userMessage("hi")
        let m2 = ChatMessage(role: .assistant, content: "hello")
        coordinator.messages = [m1, m2]

        #expect(coordinator.sideEffectNotePaths(afterRewindTo: m2.id).isEmpty)
        #expect(coordinator.sideEffectNotePaths(afterRewindTo: UUID()).isEmpty)
    }
}
