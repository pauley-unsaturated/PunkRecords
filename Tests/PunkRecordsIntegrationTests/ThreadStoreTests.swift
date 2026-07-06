import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// End-to-end `FileSystemThreadStore` behavior over a real temp vault: per-thread
/// JSON round-trips, lightweight summaries, deletion, atomic writes, and one-time
/// migration from the legacy single-transcript format. Pure decisions (title
/// derivation, sort, migration gate, codable shape) are unit-tested in Core
/// (`ChatThreadTests`); these exercise the actual file I/O.
@Suite("FileSystemThreadStore — thread persistence over a temp vault")
struct ThreadStoreTests {
    let factory = TempVaultFactory()

    private func sampleThread(title: String = "hello", body: String = "hello world") -> ChatThread {
        var thread = ChatThread()
        thread.update(messages: [
            ChatMessage(role: .user, content: body),
            ChatMessage(role: .assistant, content: "sure, here's an answer"),
        ])
        return thread
    }

    @Test("Save then load round-trips a thread's messages and metadata")
    func saveLoadRoundTrip() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        let thread = sampleThread()
        try await store.save(thread)

        // The physical file lands at the conventional path.
        let expected = vault.rootURL.appendingPathComponent(
            VaultPaths.chatThreadPath(forThreadID: thread.id)
        )
        #expect(FileManager.default.fileExists(atPath: expected.path))

        let loaded = try await store.load(id: thread.id)
        #expect(loaded == thread)
    }

    @Test("Loading an unknown id returns nil")
    func loadMissingReturnsNil() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)
        #expect(try await store.load(id: UUID()) == nil)
    }

    @Test("Summaries list every thread without loading full bodies")
    func summariesList() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        let first = sampleThread(body: "first question")
        var second = ChatThread()
        second.update(
            messages: [ChatMessage(role: .user, content: "second question")],
            now: first.updatedAt.addingTimeInterval(60)
        )

        try await store.save(first)
        try await store.save(second)

        let summaries = ChatThreadHelpers.sortedSummaries(try await store.summaries())
        #expect(summaries.count == 2)
        // Newest first.
        #expect(summaries.first?.id == second.id)
        #expect(summaries.first?.title == "second question")
        #expect(summaries.first?.messageCount == 1)
        #expect(summaries.last?.messageCount == 2)
    }

    @Test("Empty vault (no threads dir) lists no summaries")
    func summariesEmptyVault() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)
        #expect(try await store.summaries().isEmpty)
    }

    @Test("Delete removes a thread; deleting a missing id is a no-op")
    func deleteThread() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        let thread = sampleThread()
        try await store.save(thread)
        try await store.delete(id: thread.id)
        #expect(try await store.load(id: thread.id) == nil)
        #expect(try await store.summaries().isEmpty)

        // No-op for an id that was never stored.
        try await store.delete(id: UUID())
    }

    @Test("Overwriting a thread replaces its content atomically without stray temp files")
    func overwriteIsAtomic() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        var thread = sampleThread(body: "v1")
        try await store.save(thread)
        thread.update(messages: thread.messages + [ChatMessage(role: .user, content: "a follow-up")])
        try await store.save(thread)

        let loaded = try await store.load(id: thread.id)
        #expect(loaded?.messages.count == 3)

        // The atomic write-then-rename must not leave `.tmp` staging files behind.
        let dir = vault.rootURL.appendingPathComponent(VaultPaths.chatThreadsDirectory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries.allSatisfy { $0.hasSuffix(".json") })
        #expect(entries.count == 1)
    }

    // MARK: - Forking

    @Test("Fork → save → reload preserves lineage and sliced messages; original untouched")
    func forkSaveReloadRoundTrip() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        // A four-message source conversation, saved as-is.
        var source = ChatThread()
        source.update(messages: [
            ChatMessage(role: .user, content: "What is in my vault?"),
            ChatMessage(role: .assistant, content: "Notes about DSP."),
            ChatMessage(role: .user, content: "Tell me more about filters."),
            ChatMessage(role: .assistant, content: "Filters shape frequency content."),
        ])
        try await store.save(source)
        let sourceOnDiskBeforeFork = try #require(try await store.load(id: source.id))

        // Fork at the first assistant reply, then persist the branch.
        let branchPoint = source.messages[1]
        let fork = try #require(ChatThreadHelpers.fork(source, atMessageID: branchPoint.id))
        try await store.save(fork)

        // The fork reloads with its lineage and sliced messages intact.
        let reloadedFork = try #require(try await store.load(id: fork.id))
        #expect(reloadedFork.parentThreadID == source.id)
        #expect(reloadedFork.forkedAtMessageID == branchPoint.id)
        #expect(reloadedFork.messages.map(\.id) == [source.messages[0].id, source.messages[1].id])
        #expect(reloadedFork.messages.map(\.content) == ["What is in my vault?", "Notes about DSP."])

        // The original thread on disk is completely unchanged by the fork.
        let sourceOnDiskAfterFork = try #require(try await store.load(id: source.id))
        #expect(sourceOnDiskAfterFork == sourceOnDiskBeforeFork)
        #expect(sourceOnDiskAfterFork.parentThreadID == nil)
        #expect(sourceOnDiskAfterFork.messages.count == 4)

        // Both threads are now discoverable.
        #expect(try await store.summaries().count == 2)
    }

    @Test("Summaries flag forked threads via hasParent, plain threads do not")
    func summariesFlagForkedThreads() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        let source = sampleThread(body: "root question")
        try await store.save(source)
        let fork = try #require(ChatThreadHelpers.fork(source, atMessageID: source.messages[0].id))
        try await store.save(fork)

        let summaries = try await store.summaries()
        let sourceSummary = try #require(summaries.first { $0.id == source.id })
        let forkSummary = try #require(summaries.first { $0.id == fork.id })
        #expect(!sourceSummary.hasParent)
        #expect(forkSummary.hasParent)
    }

    // MARK: - Focus note (PUNK-9ss)

    @Test("Save then load preserves a thread's focus note")
    func focusNoteRoundTrip() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        var thread = ChatThread()
        thread.update(
            messages: [ChatMessage(role: .user, content: "about filters")],
            focusNote: ThreadFocusNote(title: "DSP Filters", path: "dsp/filters.md")
        )
        try await store.save(thread)

        let loaded = try #require(try await store.load(id: thread.id))
        #expect(loaded.focusNote == ThreadFocusNote(title: "DSP Filters", path: "dsp/filters.md"))
    }

    @Test("Summaries expose the focus note without materializing message bodies")
    func summariesExposeFocusNote() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        var thread = ChatThread()
        thread.update(
            messages: [
                ChatMessage(role: .user, content: "a long body that summaries must not load"),
                ChatMessage(role: .assistant, content: "another long body"),
            ],
            focusNote: ThreadFocusNote(title: "Actor Reentrancy", path: "swift/actor.md")
        )
        try await store.save(thread)

        let summaries = try await store.summaries()
        let summary = try #require(summaries.first { $0.id == thread.id })
        #expect(summary.focusNote == ThreadFocusNote(title: "Actor Reentrancy", path: "swift/actor.md"))
        #expect(summary.messageCount == 2)
    }

    @Test("A thread with no note context saves and loads a nil focus note")
    func focusNoteNilRoundTrip() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        let thread = sampleThread() // update() with no focusNote ⇒ nil
        try await store.save(thread)
        let loaded = try #require(try await store.load(id: thread.id))
        #expect(loaded.focusNote == nil)
        let summary = try #require(try await store.summaries().first { $0.id == thread.id })
        #expect(summary.focusNote == nil)
    }

    // MARK: - Backward compatibility (old-format thread files)

    @Test("An old-format thread file (no schemaVersion / parentThreadID / focusNote) still loads and lists")
    func oldFormatThreadFileLoads() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        // Hand-write a thread file in the pre-PUNK-9ss shape: no schemaVersion,
        // no parentThreadID, no focusNote — one message with the legacy field set.
        let threadID = UUID()
        let messageID = UUID()
        let json = """
        {
          "id": "\(threadID.uuidString)",
          "title": "legacy thread",
          "createdAt": 0,
          "updatedAt": 5,
          "messages": [
            {
              "id": "\(messageID.uuidString)",
              "role": "user",
              "content": "legacy question",
              "attachments": [],
              "attachmentTranscript": "",
              "timestamp": 0
            }
          ]
        }
        """
        let dir = vault.rootURL.appendingPathComponent(VaultPaths.chatThreadsDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = vault.rootURL.appendingPathComponent(VaultPaths.chatThreadPath(forThreadID: threadID))
        try Data(json.utf8).write(to: fileURL)

        // It lists (header-only decode) with the new fields defaulting to nil.
        let summary = try #require(try await store.summaries().first { $0.id == threadID })
        #expect(summary.title == "legacy thread")
        #expect(summary.messageCount == 1)
        #expect(summary.parentThreadID == nil)
        #expect(!summary.hasParent)
        #expect(summary.focusNote == nil)

        // And it loads fully, defaulting schemaVersion + focusNote leniently.
        let loaded = try #require(try await store.load(id: threadID))
        #expect(loaded.schemaVersion == ChatThread.currentSchemaVersion)
        #expect(loaded.focusNote == nil)
        #expect(loaded.parentThreadID == nil)
        #expect(loaded.messages.map(\.content) == ["legacy question"])
        #expect(loaded.messages[0].id == messageID)
    }

    // MARK: - Migration

    @Test("Migrates a legacy transcript into a thread and retires the legacy file")
    func migratesLegacyTranscript() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }

        // Seed a legacy transcript file using the canonical renderer.
        let legacyMessages = [
            ChatMessage(role: .user, content: "What's in my vault?"),
            ChatMessage(role: .assistant, content: "Notes about DSP."),
        ]
        let legacyURL = vault.rootURL.appendingPathComponent(VaultPaths.legacyChatTranscriptPath)
        try LegacyChatTranscript.render(legacyMessages).write(to: legacyURL, atomically: true, encoding: .utf8)

        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)
        let migrated = try await store.migrateLegacyTranscriptIfNeeded()

        let thread = try #require(migrated)
        #expect(thread.title == "What's in my vault?")
        #expect(thread.messages.map(\.role) == [.user, .assistant])
        #expect(thread.messages[0].content == "What's in my vault?")

        // The thread is discoverable via the store, and the legacy file is retired.
        #expect(try await store.summaries().count == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let retiredURL = vault.rootURL.appendingPathComponent(VaultPaths.legacyChatTranscriptRetiredPath)
        #expect(FileManager.default.fileExists(atPath: retiredURL.path))
    }

    @Test("Migration is a one-time operation — running it again does nothing")
    func migrationRunsOnce() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }

        let legacyURL = vault.rootURL.appendingPathComponent(VaultPaths.legacyChatTranscriptPath)
        try LegacyChatTranscript.render([ChatMessage(role: .user, content: "hi")])
            .write(to: legacyURL, atomically: true, encoding: .utf8)

        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)
        #expect(try await store.migrateLegacyTranscriptIfNeeded() != nil)
        // Second call: legacy file already retired + a thread exists → no-op.
        #expect(try await store.migrateLegacyTranscriptIfNeeded() == nil)
        #expect(try await store.summaries().count == 1)
    }

    @Test("No migration when threads already exist")
    func noMigrationWhenThreadsExist() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)

        // A thread already exists; a stray legacy file must NOT overwrite state.
        try await store.save(sampleThread())
        let legacyURL = vault.rootURL.appendingPathComponent(VaultPaths.legacyChatTranscriptPath)
        try LegacyChatTranscript.render([ChatMessage(role: .user, content: "old")])
            .write(to: legacyURL, atomically: true, encoding: .utf8)

        #expect(try await store.migrateLegacyTranscriptIfNeeded() == nil)
        #expect(try await store.summaries().count == 1)
    }

    @Test("No migration when there is no legacy transcript")
    func noMigrationWithoutLegacy() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = FileSystemThreadStore(vaultRoot: vault.rootURL)
        #expect(try await store.migrateLegacyTranscriptIfNeeded() == nil)
        #expect(try await store.summaries().isEmpty)
    }
}
