import Foundation

/// One heading in a document's outline, with the ranges and ancestry that the
/// editor features (refile, folding, inspector) need.
public struct HeadingNode: Sendable, Equatable {
    /// ATX level, 1 (`#`) through 6 (`######`).
    public let level: Int
    /// The heading text with the leading `#`s and surrounding whitespace stripped.
    public let title: String
    /// UTF-16 range of the heading line itself (excluding its trailing newline).
    public let headingRange: NSRange
    /// UTF-16 range of the heading's whole section: the heading line through the
    /// end of its subtree — everything up to the next heading of the same or a
    /// higher level (or end of text). This is the span a refile would move.
    public let sectionRange: NSRange
    /// Ancestor titles from the root down to and including this heading, e.g.
    /// `["Guide", "Setup", "Install"]`. Useful for `A ▸ B ▸ C` path display.
    public let path: [String]

    public init(level: Int, title: String, headingRange: NSRange, sectionRange: NSRange, path: [String]) {
        self.level = level
        self.title = title
        self.headingRange = headingRange
        self.sectionRange = sectionRange
        self.path = path
    }
}

/// Parses a markdown body into its heading structure. Pure and AppKit-free so
/// the outline logic is unit-testable; the editor and pickers consume it.
public enum HeadingOutline {
    /// Parse `text` into a flat, document-order list of headings. Lines that
    /// look like ATX headings inside fenced code blocks are ignored.
    public static func parse(_ text: String) -> [HeadingNode] {
        let ns = text as NSString
        let raw = scanHeadingLines(ns)
        guard !raw.isEmpty else { return [] }

        // Section range: from each heading to the next heading of level <= its
        // own (or end of text).
        var nodes: [HeadingNode] = []
        var ancestors: [(level: Int, title: String)] = []
        for (i, head) in raw.enumerated() {
            var sectionEnd = ns.length
            for next in raw[(i + 1)...] where next.level <= head.level {
                sectionEnd = next.lineRange.location
                break
            }
            let sectionRange = NSRange(location: head.lineRange.location, length: sectionEnd - head.lineRange.location)

            // Maintain the ancestor stack for the path.
            while let last = ancestors.last, last.level >= head.level { ancestors.removeLast() }
            let path = ancestors.map(\.title) + [head.title]
            ancestors.append((head.level, head.title))

            nodes.append(
                HeadingNode(
                    level: head.level,
                    title: head.title,
                    headingRange: head.lineRange,
                    sectionRange: sectionRange,
                    path: path
                )
            )
        }
        return nodes
    }

    // MARK: - Line scanning

    private struct RawHeading {
        let level: Int
        let title: String
        let lineRange: NSRange
    }

    private static func scanHeadingLines(_ ns: NSString) -> [RawHeading] {
        var headings: [RawHeading] = []
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            guard !inFence, let heading = Self.parseHeadingLine(line, lineRange: lineRange) else { return }
            headings.append(heading)
        }
        return headings
    }

    /// Parse a single line as an ATX heading (`#`…`######` + space + text), or
    /// nil. `enumerateSubstrings(.byLines)` gives the line without its newline,
    /// and `lineRange` already excludes the terminator.
    private static func parseHeadingLine(_ line: String, lineRange: NSRange) -> RawHeading? {
        var level = 0
        let scalars = Array(line.unicodeScalars)
        while level < scalars.count, scalars[level] == "#" { level += 1 }
        guard (1...6).contains(level) else { return nil }
        // A valid ATX heading needs whitespace (or end) after the run of `#`.
        if level < scalars.count {
            let after = scalars[level]
            guard after == " " || after == "\t" else { return nil }
        }
        let title = String(String.UnicodeScalarView(scalars[level...]))
            .trimmingCharacters(in: .whitespaces)
        return RawHeading(level: level, title: title, lineRange: lineRange)
    }
}
