import Foundation
import NaturalLanguage
import PunkRecordsCore

/// On-device ``ThreadEmbedder`` backed by NaturalLanguage sentence embeddings
/// (`NLEmbedding.sentenceEmbedding(for: .english)`). Runs locally with zero API
/// cost.
///
/// The `NLEmbedding` handle is loaded lazily and at most once (the language asset
/// can be a few hundred MB and isn't always installed). When it is unavailable on
/// the host, ``vector(for:)`` returns `nil` for every input, so semantic thread
/// search degrades to keyword results.
public final class NLThreadEmbedder: ThreadEmbedder, @unchecked Sendable {
    // NLEmbedding is a reference type; sentence-vector lookups are read-only after
    // load. The lock guards the lazy load and every read, so the handle is
    // initialized once even under concurrent first calls.
    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?

    public init() {}

    /// Whether the sentence-embedding model is available on this host. Lets tests
    /// (and callers) probe and skip gracefully when the asset isn't installed.
    public var isAvailable: Bool {
        resolvedEmbedding() != nil
    }

    public func vector(for text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding = resolvedEmbedding() else { return nil }
        guard let vector = embedding.vector(for: trimmed) else { return nil }
        return vector.map(Float.init)
    }

    private func resolvedEmbedding() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            loaded = true
        }
        return embedding
    }
}
