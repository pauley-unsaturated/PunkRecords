import Foundation

/// Computes the complete set of file rewrites for a refile, without performing
/// any I/O. Composing `HeadingRefile` (the move) and `HeadingRefileLinks` (the
/// optional link update) here — as a pure function over the vault's notes —
/// keeps the risky multi-file orchestration unit-testable; the app layer just
/// writes the returned changes through the repository.
public enum RefilePlan {
    /// One note whose content the refile changes.
    public struct Change: Sendable, Equatable {
        public let path: String
        public let newContent: String

        public init(path: String, newContent: String) {
            self.path = path
            self.newContent = newContent
        }
    }

    /// A note as seen by the planner.
    public struct Note: Sendable, Equatable {
        public let path: String
        public let title: String
        public let content: String

        public init(path: String, title: String, content: String) {
            self.path = path
            self.title = title
            self.content = content
        }
    }

    /// Describes the move to plan.
    public struct Request: Sendable, Equatable {
        /// The note the heading currently lives in.
        public let sourcePath: String
        /// The heading's section range (from `HeadingOutline`) in the source.
        public let sectionRange: NSRange
        /// The moved heading's title (for link rewriting).
        public let headingTitle: String
        /// The note to move the heading into (may equal `sourcePath`).
        public let destPath: String
        /// The destination heading to append under, or nil to append at the end
        /// of the destination note.
        public let targetHeadingPath: [String]?
        /// When true, `[[source#heading]]` links are rewritten to the dest note.
        public let updateLinks: Bool

        public init(
            sourcePath: String,
            sectionRange: NSRange,
            headingTitle: String,
            destPath: String,
            targetHeadingPath: [String]?,
            updateLinks: Bool
        ) {
            self.sourcePath = sourcePath
            self.sectionRange = sectionRange
            self.headingTitle = headingTitle
            self.destPath = destPath
            self.targetHeadingPath = targetHeadingPath
            self.updateLinks = updateLinks
        }
    }

    /// Plan a refile over `notes` (the whole vault, source and destination
    /// included). Returns the changed notes, or nil if the inputs are invalid
    /// (unknown paths, bad range, or moving a heading into its own subtree).
    public static func make(notes: [Note], _ request: Request) -> [Change]? {
        let sourcePath = request.sourcePath
        let destPath = request.destPath
        guard let source = notes.first(where: { $0.path == sourcePath }),
              let dest = notes.first(where: { $0.path == destPath }),
              let extraction = HeadingRefile.extract(from: source.content, sectionRange: request.sectionRange) else {
            return nil
        }

        // Working copy of every note's content, keyed by path.
        var working: [String: String] = Dictionary(
            notes.map { ($0.path, $0.content) },
            uniquingKeysWith: { first, _ in first }
        )
        working[sourcePath] = extraction.remainingSource

        let sameNote = sourcePath == destPath
        let baseDest = sameNote ? extraction.remainingSource : dest.content

        // Resolve where to append in the destination.
        let insertEnd: Int?
        if let targetHeadingPath = request.targetHeadingPath {
            guard let node = HeadingOutline.parse(baseDest).first(where: { $0.path == targetHeadingPath }) else {
                return nil  // target heading vanished (e.g. it was inside the moved subtree)
            }
            insertEnd = NSMaxRange(node.sectionRange)
        } else {
            insertEnd = nil
        }
        working[destPath] = HeadingRefile.append(extraction.section, into: baseDest, endingAt: insertEnd)

        // Optional link update across the (already-moved) note set.
        if request.updateLinks, source.title.caseInsensitiveCompare(dest.title) != .orderedSame {
            let titleToPath = Dictionary(notes.map { ($0.title, $0.path) }, uniquingKeysWith: { first, _ in first })
            let currentNotes = notes.map { (title: $0.title, content: working[$0.path] ?? $0.content) }
            let rewrites = HeadingRefileLinks.rewriteHeadingLinks(
                in: currentNotes,
                movingHeading: request.headingTitle,
                fromNote: source.title,
                toNote: dest.title
            )
            for rewrite in rewrites {
                if let path = titleToPath[rewrite.title] {
                    working[path] = rewrite.newContent
                }
            }
        }

        return notes.compactMap { note in
            guard let updated = working[note.path], updated != note.content else { return nil }
            return Change(path: note.path, newContent: updated)
        }
    }
}
