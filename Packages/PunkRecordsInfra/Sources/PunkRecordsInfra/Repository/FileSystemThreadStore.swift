import Foundation
import PunkRecordsCore

/// File-backed ``ThreadStore``. Persists one JSON file per ``ChatThread`` under
/// `{vault}/.punkrecords/threads/{id}.json`. All mutating paths use
/// write-then-atomic-rename (mirroring ``FileSystemCrashRecoveryStore``) so a
/// crash mid-write never leaves a torn thread file — a reader sees either the
/// previous complete file or the new one, never a blend.
///
/// `summaries()` decodes only each file's header (id / title / updatedAt) plus a
/// message count, never materializing message bodies, so listing many threads
/// stays cheap.
public actor FileSystemThreadStore: ThreadStore {
    private let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot.standardizedFileURL
    }

    private var threadsDirURL: URL {
        vaultRoot.appendingPathComponent(VaultPaths.chatThreadsDirectory)
    }

    private func threadURL(id: UUID) -> URL {
        vaultRoot.appendingPathComponent(VaultPaths.chatThreadPath(forThreadID: id))
    }

    // Numeric (deferredToDate) date coding round-trips `Date` exactly; sorted +
    // pretty output keeps the files diff-friendly and deterministic.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    // MARK: - ThreadStore

    public func summaries() async throws -> [ThreadSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: threadsDirURL.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: threadsDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let decoder = Self.makeDecoder()
        var summaries: [ThreadSummary] = []
        for url in entries {
            guard VaultPaths.chatThreadID(fromThreadFilename: url.lastPathComponent) != nil else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let header = try? decoder.decode(ThreadFileHeader.self, from: data) else {
                continue
            }
            summaries.append(header.summary)
        }
        return summaries
    }

    public func load(id: UUID) async throws -> ChatThread? {
        let url = threadURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(ChatThread.self, from: data)
    }

    public func save(_ thread: ChatThread) async throws {
        let fm = FileManager.default
        let dir = threadsDirURL
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let data = try Self.makeEncoder().encode(thread)
        let target = threadURL(id: thread.id)

        // Write-then-atomic-rename. Stage the bytes in a sibling temp file (same
        // directory ⇒ same filesystem ⇒ rename is atomic), then swap it into
        // place. A crash before the swap leaves only the temp (skipped by
        // summaries(), since it isn't a `{uuid}.json` name); a crash after
        // leaves a fully-written file.
        let temp = dir.appendingPathComponent("\(thread.id.uuidString).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    public func delete(id: UUID) async throws {
        let target = threadURL(id: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        try fm.removeItem(at: target)
    }

    // MARK: - Legacy migration

    /// One-time conversion of the legacy single-transcript persistence into a
    /// thread. Runs on first open: if a legacy transcript with content exists and
    /// no threads are stored yet, its messages become a new thread (title derived
    /// from the first user message) and the legacy file is retired so it is never
    /// re-migrated. Returns the created thread, or `nil` when nothing migrated.
    @discardableResult
    public func migrateLegacyTranscriptIfNeeded() async throws -> ChatThread? {
        let fm = FileManager.default
        let legacyURL = vaultRoot.appendingPathComponent(VaultPaths.legacyChatTranscriptPath)
        let legacyExists = fm.fileExists(atPath: legacyURL.path)

        let legacyMessages: [ChatMessage]
        if legacyExists, let text = try? String(contentsOf: legacyURL, encoding: .utf8) {
            legacyMessages = (try? LegacyChatTranscript.parse(text)) ?? []
        } else {
            legacyMessages = []
        }

        let existing = try await summaries()
        guard ChatThreadHelpers.shouldMigrateLegacyTranscript(
            hasLegacyContent: !legacyMessages.isEmpty,
            hasExistingThreads: !existing.isEmpty
        ) else {
            // A legacy file with no usable content is retired too, so a subsequent
            // real transcript isn't blocked and we don't re-scan it every open.
            if legacyExists, legacyMessages.isEmpty {
                retireLegacyTranscript(at: legacyURL)
            }
            return nil
        }

        var thread = ChatThread(messages: legacyMessages)
        thread.title = ChatThreadHelpers.deriveTitle(from: legacyMessages)
        try await save(thread)
        retireLegacyTranscript(at: legacyURL)
        return thread
    }

    /// Rename the legacy transcript aside so it is retired without discarding its
    /// content. Best-effort: on any failure, fall back to deleting it.
    private func retireLegacyTranscript(at legacyURL: URL) {
        let fm = FileManager.default
        let retiredURL = vaultRoot.appendingPathComponent(VaultPaths.legacyChatTranscriptRetiredPath)
        do {
            if fm.fileExists(atPath: retiredURL.path) {
                _ = try fm.replaceItemAt(retiredURL, withItemAt: legacyURL)
            } else {
                try fm.moveItem(at: legacyURL, to: retiredURL)
            }
        } catch {
            try? fm.removeItem(at: legacyURL)
        }
    }

    /// Decodes just the fields the switcher needs. `messages` is decoded into a
    /// count-only probe so bodies are never materialized (see `MessageCountProbe`).
    private struct ThreadFileHeader: Decodable {
        let id: UUID
        let title: String
        let updatedAt: Date
        let messages: [MessageCountProbe]

        var summary: ThreadSummary {
            ThreadSummary(id: id, title: title, updatedAt: updatedAt, messageCount: messages.count)
        }
    }

    /// Decodes nothing — used to count array elements without building messages.
    /// An unkeyed container advances one element per `decode(_:)`, so a
    /// `[MessageCountProbe]` yields the message count while skipping all bodies.
    private struct MessageCountProbe: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
