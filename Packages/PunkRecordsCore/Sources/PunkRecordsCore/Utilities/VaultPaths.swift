import Foundation

/// Convention for resolving on-disk paths for images dragged, pasted, or
/// otherwise authored into a vault note. Lives in Core so the same rules
/// govern the editor's paste handler, future screenshot capture, and any
/// agentic write path.
///
/// Convention:
///   - Each note that owns image attachments gets a sibling directory
///     `attachments/{note-slug}/` rooted at the vault.
///   - `{note-slug}` is derived from the note's relative path with the
///     `.md` extension removed, mirrored 1:1 — `Daily/2026-05-18.md`
///     keeps its hierarchy at `attachments/Daily/2026-05-18/foo.png`.
///   - Collisions within a single note's attachments dir get a short
///     UUID suffix on the filename stem: `foo.png` → `foo-a1b2c3d4.png`.
///   - Markdown references use a vault-relative path:
///     `![alt](attachments/Daily/2026-05-18/foo.png)`. No leading slash;
///     no `file://` URLs. Vault-relative keeps notes portable.
///
/// This convention is duplicated in CLAUDE.md so the contract is visible
/// to humans and agents alike. Keep them in sync.
public enum VaultPaths {

    /// The vault-relative directory that holds images for the given note.
    /// Returns paths like `"attachments/Daily/2026-05-18"`. Always uses
    /// forward slashes so paths embedded into markdown render identically
    /// across platforms.
    public static func imageDirectory(forNoteAt path: RelativePath) -> RelativePath {
        let stem = (path as NSString).deletingPathExtension
        return "attachments/\(stem)"
    }

    /// Vault-relative path for a new image attached to a given note, with
    /// collision handling. `exists` is an async predicate that returns
    /// whether a vault-relative path is already taken (e.g. a repository
    /// lookup). The first attempt uses `originalFilename` as-is; on
    /// collision, an 8-char UUID suffix is appended to the stem.
    public static func imagePath(
        forNoteAt notePath: RelativePath,
        originalFilename: String,
        exists: @Sendable (RelativePath) async -> Bool
    ) async -> RelativePath {
        let dir = imageDirectory(forNoteAt: notePath)
        let safe = sanitize(filename: originalFilename)
        let firstCandidate = "\(dir)/\(safe)"
        if !(await exists(firstCandidate)) { return firstCandidate }

        let stem = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        let suffixExt = ext.isEmpty ? "" : ".\(ext)"

        // Probe a handful of UUID-suffixed candidates. UUID space is huge;
        // multiple collisions on the same note's directory in one session
        // mean something is very wrong upstream, but the bounded loop
        // keeps us from sticking around if `exists` is misbehaving.
        for _ in 0..<8 {
            let suffix = String(UUID().uuidString.prefix(8)).lowercased()
            let candidate = "\(dir)/\(stem)-\(suffix)\(suffixExt)"
            if !(await exists(candidate)) { return candidate }
        }

        // Fallback: timestamp-based suffix. Practically unreachable.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "\(dir)/\(stem)-\(stamp)\(suffixExt)"
    }

    // MARK: - Crash-recovery sidecars

    /// Vault-relative directory holding crash-recovery sidecars — one `.md`
    /// file per note that has unsaved edits. Lives under `.punkrecords/`, which
    /// is already in the default `ignoredPaths` and is hidden, so neither the
    /// FS watcher nor the search indexer mistakes a sidecar for a real note.
    public static var recoveryDirectory: RelativePath { ".punkrecords/recovery" }

    /// Vault-relative path of the crash-recovery sidecar for a note, keyed by
    /// the note's stable `id` (not its on-disk path) so the sidecar keeps
    /// tracking the same note across renames and moves.
    public static func recoverySidecarPath(forNoteID id: DocumentID) -> RelativePath {
        "\(recoveryDirectory)/\(id.uuidString).md"
    }

    /// Recover the note id encoded in a recovery sidecar filename, or nil if
    /// the filename is not a `{uuid}.md` sidecar (e.g. a stray in-flight `.tmp`
    /// write left by an interrupted atomic save). Callers use this to skip
    /// non-sidecar entries when scanning the recovery directory.
    public static func recoveryNoteID(fromSidecarFilename filename: String) -> DocumentID? {
        guard (filename as NSString).pathExtension.lowercased() == "md" else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return UUID(uuidString: stem)
    }

    // MARK: - Chat threads

    /// Vault-relative directory holding persisted chat conversations — one JSON
    /// file per ``ChatThread``, keyed by thread id. Lives under `.punkrecords/`,
    /// which is hidden and already in the default `ignoredPaths`, so the FS
    /// watcher and search indexer never mistake a thread file for a note.
    public static var chatThreadsDirectory: RelativePath { ".punkrecords/threads" }

    /// Vault-relative path of the JSON file backing a chat thread, keyed by its
    /// stable `id` so the same thread maps to the same file across sessions.
    public static func chatThreadPath(forThreadID id: UUID) -> RelativePath {
        "\(chatThreadsDirectory)/\(id.uuidString).json"
    }

    /// Recover the thread id encoded in a thread filename, or nil if the filename
    /// is not a `{uuid}.json` thread file (e.g. a stray in-flight `.tmp` write).
    /// Callers use this to skip non-thread entries when scanning the directory.
    public static func chatThreadID(fromThreadFilename filename: String) -> UUID? {
        guard (filename as NSString).pathExtension.lowercased() == "json" else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return UUID(uuidString: stem)
    }

    /// Vault-relative path of the sidecar cache holding per-thread embedding
    /// vectors for semantic thread search (see `EmbeddingIndexingThreadStore`).
    /// Lives beside the thread JSON files; its non-`{uuid}.json` name means
    /// ``chatThreadID(fromThreadFilename:)`` — and therefore the thread store's
    /// `summaries()` scan — skips it. Keyed by thread id inside the file, with
    /// each entry invalidated by its thread's `updatedAt`.
    public static var chatThreadEmbeddingCachePath: RelativePath {
        "\(chatThreadsDirectory)/embeddings-cache.json"
    }

    /// Vault-relative path of the legacy single-transcript chat persistence
    /// (`punkrecords-chat-transcript-v1`) the per-thread store migrates away from.
    public static var legacyChatTranscriptPath: RelativePath { ".punkrecords/chat-transcript.md" }

    /// Where the legacy transcript is renamed after a successful migration, so it
    /// is retired (never re-migrated) without discarding the original content.
    public static var legacyChatTranscriptRetiredPath: RelativePath {
        ".punkrecords/chat-transcript.migrated.md"
    }

    // MARK: - Web content cache

    /// Vault-relative directory where fetched web pages are cached as raw HTML
    /// for offline anchor rendering. Lives under `Web/_cache/` — a visible
    /// `Web/` tree the user can browse, with the derived cache tucked under a
    /// leading-underscore subdir so it reads as "generated" and sorts away from
    /// hand-authored notes. Callers should add `Web/_cache` to `ignoredPaths`
    /// so the search indexer skips it.
    public static var webCacheDirectory: RelativePath { "Web/_cache" }

    /// Vault-relative path of the cached HTML for a fetched web page, keyed by a
    /// slug (see ``WebSlug/slug(forURL:)``) so the same URL maps to a stable
    /// file across fetches. Always `.html` under ``webCacheDirectory``.
    public static func webCachePath(forSlug slug: String) -> RelativePath {
        let safe = slug.isEmpty ? "section" : slug
        return "\(webCacheDirectory)/\(safe).html"
    }

    /// Convenience: the cache path for a fetched URL, deriving the slug from the
    /// URL. Equivalent to `webCachePath(forSlug: WebSlug.slug(forURL:))`.
    public static func webCachePath(forURL url: URL) -> RelativePath {
        webCachePath(forSlug: WebSlug.slug(forURL: url))
    }

    /// Markdown image reference text for a given vault-relative image
    /// path. Always uses forward slashes, never leading `/`, never
    /// `file://`. Pass an `alt` description for accessibility (empty
    /// string is allowed but discouraged).
    public static func markdownImageReference(
        alt: String,
        imagePath: RelativePath
    ) -> String {
        let escapedAlt = alt
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "[", with: "\\[")
        let escapedPath = imagePath
            .replacingOccurrences(of: " ", with: "%20")
        return "![\(escapedAlt)](\(escapedPath))"
    }

    /// Strip path separators + characters that are awkward in filenames
    /// across HFS+/APFS and web URLs. Mirrors `FilenameHelpers.sanitizeFilename`
    /// but tuned for arbitrary user-supplied image filenames (which may
    /// arrive from the macOS clipboard with odd names like
    /// `Screenshot 2026-05-18 at 09.42.31.png`).
    private static func sanitize(filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let joined = filename.components(separatedBy: invalid).joined(separator: "-")
        // Collapse whitespace into single dashes; trim leading/trailing dashes.
        var collapsed = joined
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        // Defense in depth: no ".." may survive. Separators are already gone,
        // but a name like "..-..-etc-passwd" still reads as traversal to
        // scanners and humans. Single dots (e.g. "09.42.31.png") are fine.
        while collapsed.contains("..") {
            collapsed = collapsed.replacingOccurrences(of: "..", with: "-")
        }
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
