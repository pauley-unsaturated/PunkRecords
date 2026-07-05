import Foundation

/// Turns text into a dense embedding vector for semantic thread search. Core
/// declares the seam; Infra implements it on-device via NaturalLanguage's
/// `NLEmbedding` (`NLThreadEmbedder`), so semantic search costs no API calls.
///
/// `vector(for:)` returns `nil` when embeddings are unavailable on the host (the
/// sentence-embedding language asset isn't installed) — callers degrade semantic
/// search to keyword results.
public protocol ThreadEmbedder: Sendable {
    /// Embed arbitrary text. `nil` when embeddings are unavailable on this host.
    func vector(for text: String) async -> [Float]?
}

/// Supplies cached per-thread embedding vectors to ``ReadThreadTool``'s semantic
/// mode. Infra's `EmbeddingIndexingThreadStore` implements it: it computes each
/// thread's vector on save and invalidates it when the thread's `updatedAt`
/// changes.
///
/// `vector(forThreadID:updatedAt:)` takes the thread's *current* `updatedAt` so
/// the implementation can honor staleness (a cached vector is only reused when
/// its stored `updatedAt` matches). Returns `nil` when no vector is available —
/// embeddings unavailable, or the thread could not be embedded — so semantic
/// search degrades to keyword.
public protocol ThreadVectorSource: Sendable {
    func vector(forThreadID id: UUID, updatedAt: Date) async -> [Float]?
}
