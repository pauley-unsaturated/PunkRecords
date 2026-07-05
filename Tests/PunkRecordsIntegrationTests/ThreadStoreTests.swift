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
