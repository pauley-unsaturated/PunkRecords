import Foundation

/// Computes how `[[Note#Heading]]` wikilinks must change when a heading is
/// refiled from one note to another. Pure and unit-tested; the refile flow uses
/// it both to populate the "these links would change" confirmation dialog and,
/// if the user opts in, to produce the rewritten note contents.
///
/// A link is affected when its target is `<source title>#<heading>`
/// (case-insensitively, ignoring surrounding whitespace and any `|alias`). The
/// rewrite swaps only the note part, preserving the `#heading` anchor and alias.
public enum HeadingRefileLinks {
    /// One note whose content gains rewritten links.
    public struct NoteRewrite: Sendable, Equatable {
        /// The note's title (the caller maps this back to a document/path).
        public let title: String
        public let newContent: String
        /// How many links in this note were rewritten.
        public let count: Int

        public init(title: String, newContent: String, count: Int) {
            self.title = title
            self.newContent = newContent
            self.count = count
        }
    }

    /// Rewrite `[[source#heading]]` links to `[[dest#heading]]` across `notes`.
    /// Returns only the notes that actually change. No-ops when `source == dest`.
    public static func rewriteHeadingLinks(
        in notes: [(title: String, content: String)],
        movingHeading heading: String,
        fromNote source: String,
        toNote dest: String
    ) -> [NoteRewrite] {
        guard source.caseInsensitiveCompare(dest) != .orderedSame else { return [] }
        let wantedSource = source.lowercased().trimmed
        let wantedHeading = heading.lowercased().trimmed

        var rewrites: [NoteRewrite] = []
        for note in notes {
            var count = 0
            let newContent = replaceWikilinks(in: note.content) { target, alias in
                guard let (notePart, anchor) = splitAnchor(target),
                      notePart.lowercased().trimmed == wantedSource,
                      anchor.lowercased().trimmed == wantedHeading else {
                    return nil
                }
                count += 1
                let newTarget = "\(dest)#\(anchor.trimmed)"
                return alias.map { "\(newTarget)|\($0)" } ?? newTarget
            }
            if count > 0 {
                rewrites.append(NoteRewrite(title: note.title, newContent: newContent, count: count))
            }
        }
        return rewrites
    }

    // MARK: - Helpers

    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)

    /// Replace each `[[inner]]`'s inner content via `transform`, which receives
    /// the target and optional alias and returns a new inner string, or nil to
    /// leave the link unchanged.
    private static func replaceWikilinks(
        in content: String,
        transform: (_ target: String, _ alias: String?) -> String?
    ) -> String {
        let ns = content as NSString
        let matches = wikilinkRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }

        var result = ""
        var cursor = 0
        for match in matches {
            let whole = match.range
            result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            let inner = ns.substring(with: match.range(at: 1))
            let (target, alias) = splitAlias(inner)
            if let replacement = transform(target, alias) {
                result += "[[\(replacement)]]"
            } else {
                result += ns.substring(with: whole)
            }
            cursor = NSMaxRange(whole)
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// `Target|alias` → ("Target", "alias"); no pipe → (inner, nil).
    private static func splitAlias(_ inner: String) -> (target: String, alias: String?) {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts.first.map { $0.trimmed } ?? inner
        let alias = parts.count > 1 ? parts[1].trimmed : nil
        return (target, alias)
    }

    /// `Note#Heading` → ("Note", "Heading"); no `#` → nil (not a heading link).
    private static func splitAnchor(_ target: String) -> (note: String, anchor: String)? {
        guard let hash = target.firstIndex(of: "#") else { return nil }
        let note = String(target[..<hash])
        let anchor = String(target[target.index(after: hash)...])
        guard !anchor.isEmpty else { return nil }
        return (note, anchor)
    }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
