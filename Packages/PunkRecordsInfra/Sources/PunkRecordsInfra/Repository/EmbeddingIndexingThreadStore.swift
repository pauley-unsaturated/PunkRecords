import Foundation
import PunkRecordsCore

/// A ``ThreadStore`` decorator that keeps an on-device embedding for each thread
/// so ``ReadThreadTool``'s semantic mode is cheap. It forwards all storage to an
/// inner store and, on every ``save(_:)``, (re)computes the thread's sentence
/// embedding and persists it into a single sidecar cache file
/// (`.punkrecords/threads/embeddings-cache.json`), keyed by thread id.
///
/// **Invalidation is by `updatedAt`.** A cached entry is only reused when its
/// stored `updatedAt` matches the thread's current one. A stale or missing entry
/// is recomputed lazily on read (``vector(forThreadID:updatedAt:)``), so threads
/// written before embeddings existed still become searchable.
///
/// Keeping the extra behavior in a decorator keeps ``ThreadStore``'s protocol
/// clean: the app wraps its `FileSystemThreadStore` in this and hands the same
/// object to the tool as its ``ThreadVectorSource``. NaturalLanguage stays an
/// Infra-only dependency (the embedding runs inside the injected
/// ``ThreadEmbedder``, e.g. `NLThreadEmbedder`).
public actor EmbeddingIndexingThreadStore: ThreadStore, ThreadVectorSource {
    private let inner: any ThreadStore
    private let embedder: any ThreadEmbedder
    private let cacheURL: URL
    private let textBudget: Int

    /// Lazily loaded sidecar contents. `nil` until first access.
    private var cache: EmbeddingCacheFile?

    public init(
        inner: any ThreadStore,
        embedder: any ThreadEmbedder,
        vaultRoot: URL,
        textBudget: Int = 400
    ) {
        self.inner = inner
        self.embedder = embedder
        self.cacheURL = vaultRoot.standardizedFileURL
            .appendingPathComponent(VaultPaths.chatThreadEmbeddingCachePath)
        self.textBudget = textBudget
    }

    // MARK: - ThreadStore (forwarding + indexing)

    public func summaries() async throws -> [ThreadSummary] {
        try await inner.summaries()
    }

    public func load(id: UUID) async throws -> ChatThread? {
        try await inner.load(id: id)
    }

    public func save(_ thread: ChatThread) async throws {
        try await inner.save(thread)
        await indexThread(thread)
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(id: id)
        removeCacheEntry(id: id)
    }

    // MARK: - ThreadVectorSource

    public func vector(forThreadID id: UUID, updatedAt: Date) async -> [Float]? {
        loadCacheIfNeeded()
        if let entry = cache?.entries[id.uuidString], entry.matches(updatedAt: updatedAt) {
            return entry.vector
        }
        // Stale or missing: recompute from the current thread on disk, but only if
        // that thread's updatedAt still matches what the caller asked for (else the
        // caller is chasing a version that no longer exists).
        guard let thread = try? await inner.load(id: id), thread.updatedAt == updatedAt else {
            return nil
        }
        return await indexThread(thread)
    }

    // MARK: - Indexing

    /// Compute + persist the embedding for a thread. Returns the vector, or `nil`
    /// when embeddings are unavailable (in which case any stale entry is dropped
    /// so a stale vector is never served).
    @discardableResult
    private func indexThread(_ thread: ChatThread) async -> [Float]? {
        let text = ThreadTranscriptRenderer.render(thread, budget: textBudget)
        guard let vector = await embedder.vector(for: text) else {
            removeCacheEntry(id: thread.id)
            return nil
        }
        loadCacheIfNeeded()
        var file = cache ?? EmbeddingCacheFile()
        file.entries[thread.id.uuidString] = EmbeddingCacheFile.Entry(
            updatedAt: thread.updatedAt,
            dimension: vector.count,
            vector: vector
        )
        cache = file
        persist()
        return vector
    }

    private func removeCacheEntry(id: UUID) {
        loadCacheIfNeeded()
        guard var file = cache, file.entries[id.uuidString] != nil else { return }
        file.entries.removeValue(forKey: id.uuidString)
        cache = file
        persist()
    }

    // MARK: - Sidecar persistence

    private func loadCacheIfNeeded() {
        guard cache == nil else { return }
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(EmbeddingCacheFile.self, from: data) {
            cache = decoded
        } else {
            cache = EmbeddingCacheFile()
        }
    }

    /// Write the cache atomically (temp + swap), mirroring `FileSystemThreadStore`.
    /// Best-effort: a write failure just means a later read misses and recomputes,
    /// so it never surfaces as a store error.
    private func persist() {
        guard let cache else { return }
        let fm = FileManager.default
        let dir = cacheURL.deletingLastPathComponent()
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(cache)
            let temp = dir.appendingPathComponent("embeddings-cache.\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .atomic)
            do {
                if fm.fileExists(atPath: cacheURL.path) {
                    _ = try fm.replaceItemAt(cacheURL, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: cacheURL)
                }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        } catch {
            // Swallow — the cache is derived data and recomputes on the next read.
        }
    }
}

/// On-disk shape of the per-thread embedding sidecar. Keyed by thread uuid string;
/// each entry stamps the `updatedAt` it was computed from for staleness checks.
struct EmbeddingCacheFile: Codable {
    var version: Int
    var entries: [String: Entry]

    init(version: Int = 1, entries: [String: Entry] = [:]) {
        self.version = version
        self.entries = entries
    }

    struct Entry: Codable {
        var updatedAt: Date
        var dimension: Int
        var vector: [Float]

        /// Whether this entry was computed from the given `updatedAt`. Uses a tiny
        /// epsilon so a Date that round-tripped through JSON still matches exactly.
        func matches(updatedAt: Date) -> Bool {
            abs(self.updatedAt.timeIntervalSinceReferenceDate
                - updatedAt.timeIntervalSinceReferenceDate) < 0.0005
        }
    }
}
