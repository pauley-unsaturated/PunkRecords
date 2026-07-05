import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// `EmbeddingIndexingThreadStore` behavior over a real temp vault: the sidecar
/// embedding cache is written on save, invalidated when a thread's `updatedAt`
/// changes, dropped on delete, and lazily computed for threads written before the
/// cache existed. A deterministic stub embedder makes these assertions
/// host-independent; a final case exercises the real `NLThreadEmbedder`, skipped
/// gracefully when the NaturalLanguage sentence-embedding asset isn't installed.
@Suite("EmbeddingIndexingThreadStore — per-thread embedding cache")
struct ThreadEmbeddingCacheTests {
    let factory = TempVaultFactory()

    /// Deterministic, text-sensitive embedder: same text ⇒ same vector, different
    /// text ⇒ (almost surely) a different vector. No NaturalLanguage dependency.
    struct StubEmbedder: ThreadEmbedder {
        func vector(for text: String) async -> [Float]? {
            var vector = [Float](repeating: 0, count: 8)
            for (offset, scalar) in text.unicodeScalars.enumerated() {
                vector[offset % 8] += Float(scalar.value % 101)
            }
            return vector
        }
    }

    private func thread(user: String, updatedAt: Date) -> ChatThread {
        ChatThread(
            title: user,
            updatedAt: updatedAt,
            messages: [
                ChatMessage(role: .user, content: user),
                ChatMessage(role: .assistant, content: "an answer about \(user)"),
            ]
        )
    }

    @Test("save writes a cache entry retrievable by (id, updatedAt)")
    func saveWritesCacheEntry() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = EmbeddingIndexingThreadStore(
            inner: FileSystemThreadStore(vaultRoot: vault.rootURL),
            embedder: StubEmbedder(),
            vaultRoot: vault.rootURL
        )

        let t = thread(user: "reverb algorithms", updatedAt: .init(timeIntervalSince1970: 10))
        try await store.save(t)

        // The sidecar file lands at the conventional path and names the thread.
        let cacheURL = vault.rootURL.appendingPathComponent(VaultPaths.chatThreadEmbeddingCachePath)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        let raw = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(raw.contains(t.id.uuidString))

        // The vector is retrievable for the current updatedAt.
        let vector = await store.vector(forThreadID: t.id, updatedAt: t.updatedAt)
        #expect(vector != nil)
        #expect(vector?.count == 8)
    }

    @Test("Updating a thread invalidates the stale vector and re-embeds")
    func updateInvalidatesCache() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = EmbeddingIndexingThreadStore(
            inner: FileSystemThreadStore(vaultRoot: vault.rootURL),
            embedder: StubEmbedder(),
            vaultRoot: vault.rootURL
        )

        var t = thread(user: "original topic", updatedAt: .init(timeIntervalSince1970: 10))
        try await store.save(t)
        let originalUpdatedAt = t.updatedAt
        let originalVector = await store.vector(forThreadID: t.id, updatedAt: originalUpdatedAt)
        #expect(originalVector != nil)

        // Change content + bump updatedAt, then re-save.
        t.update(
            messages: t.messages + [ChatMessage(role: .user, content: "a very different subject entirely")],
            now: .init(timeIntervalSince1970: 20)
        )
        try await store.save(t)

        // The stale (old-updatedAt) lookup no longer resolves.
        #expect(await store.vector(forThreadID: t.id, updatedAt: originalUpdatedAt) == nil)
        // The fresh lookup resolves to a re-embedded (different) vector.
        let newVector = await store.vector(forThreadID: t.id, updatedAt: t.updatedAt)
        #expect(newVector != nil)
        #expect(newVector != originalVector)
    }

    @Test("delete removes the cache entry")
    func deleteRemovesEntry() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = EmbeddingIndexingThreadStore(
            inner: FileSystemThreadStore(vaultRoot: vault.rootURL),
            embedder: StubEmbedder(),
            vaultRoot: vault.rootURL
        )

        let t = thread(user: "temporary", updatedAt: .init(timeIntervalSince1970: 10))
        try await store.save(t)
        #expect(await store.vector(forThreadID: t.id, updatedAt: t.updatedAt) != nil)

        try await store.delete(id: t.id)
        #expect(await store.vector(forThreadID: t.id, updatedAt: t.updatedAt) == nil)
    }

    @Test("A thread written before the cache existed is embedded lazily on read")
    func lazyComputeForPreexistingThread() async throws {
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let fileStore = FileSystemThreadStore(vaultRoot: vault.rootURL)
        let store = EmbeddingIndexingThreadStore(
            inner: fileStore,
            embedder: StubEmbedder(),
            vaultRoot: vault.rootURL
        )

        // Persist through the bare file store, bypassing the indexing decorator,
        // so no cache entry exists yet.
        let t = thread(user: "legacy conversation", updatedAt: .init(timeIntervalSince1970: 10))
        try await fileStore.save(t)

        let cacheURL = vault.rootURL.appendingPathComponent(VaultPaths.chatThreadEmbeddingCachePath)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        // First read computes + caches it.
        let vector = await store.vector(forThreadID: t.id, updatedAt: t.updatedAt)
        #expect(vector != nil)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("Real NLThreadEmbedder produces cached vectors when the asset is available")
    func realEmbedderWhenAvailable() async throws {
        let embedder = NLThreadEmbedder()
        guard embedder.isAvailable else {
            // NaturalLanguage sentence-embedding asset not installed on this host —
            // skip gracefully (semantic search degrades to keyword in production).
            return
        }
        let (vault, cleanup) = try factory.createTempVault()
        defer { cleanup() }
        let store = EmbeddingIndexingThreadStore(
            inner: FileSystemThreadStore(vaultRoot: vault.rootURL),
            embedder: embedder,
            vaultRoot: vault.rootURL
        )

        let t = thread(user: "guitar amplifier distortion", updatedAt: .init(timeIntervalSince1970: 10))
        try await store.save(t)

        let vector = await store.vector(forThreadID: t.id, updatedAt: t.updatedAt)
        let resolved = try #require(vector)
        #expect(!resolved.isEmpty)
    }
}
