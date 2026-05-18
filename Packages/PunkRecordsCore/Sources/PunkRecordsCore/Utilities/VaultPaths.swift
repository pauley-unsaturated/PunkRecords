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
        let collapsed = joined
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
