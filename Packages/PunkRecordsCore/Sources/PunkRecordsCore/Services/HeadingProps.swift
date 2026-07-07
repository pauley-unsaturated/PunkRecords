import Foundation

/// Where the inspector's edits land: a specific heading's `> [!props]` callout,
/// or the document root (YAML frontmatter) when the caret sits above the first
/// heading.
public enum HeadingPropsTarget: Equatable, Sendable {
    case documentRoot
    case heading(HeadingNode)
}

/// Pure document surgery for per-heading (and document-root) metadata: locate,
/// read, insert, replace, and remove a ``PropsBlock`` under a heading, plus the
/// frontmatter variant. No file I/O — the App layer composes these with the
/// repository. Ranges are UTF-16 offsets, matching ``HeadingOutline``.
///
/// Round-trip and idempotency guarantees (unit-tested):
/// - `read(apply(block)) == block` for a non-empty block under a heading.
/// - `apply(apply(block)) == apply(block)` — a second write replaces, never
///   duplicates, the existing callout, and doesn't drift trailing newlines.
public enum HeadingProps {
    // MARK: - Caret → target resolution

    /// The deepest heading whose section contains `caret`, or `.documentRoot`
    /// when the caret sits above the first heading (in frontmatter / preamble).
    /// Mirrors the refile caret rule so both features agree on "the heading the
    /// cursor is in."
    public static func target(forCaret caret: Int, in nodes: [HeadingNode]) -> HeadingPropsTarget {
        guard let node = nodes.last(where: { caret >= $0.sectionRange.location && caret <= NSMaxRange($0.sectionRange) }) else {
            return .documentRoot
        }
        return .heading(node)
    }

    /// Convenience: parse `documentText` and resolve the target for `caret`.
    public static func target(forCaret caret: Int, in documentText: String) -> HeadingPropsTarget {
        target(forCaret: caret, in: HeadingOutline.parse(documentText))
    }

    // MARK: - Read / apply (target-dispatched)

    /// Read the current block for `target` out of `documentText`.
    public static func read(from documentText: String, target: HeadingPropsTarget) -> PropsBlock {
        switch target {
        case .documentRoot: return readFrontmatter(from: documentText)
        case .heading(let heading): return read(from: documentText, heading: heading)
        }
    }

    /// Return `documentText` with `block` written to `target`.
    public static func apply(_ block: PropsBlock, to documentText: String, target: HeadingPropsTarget) -> String {
        switch target {
        case .documentRoot: return applyToFrontmatter(block, documentText: documentText)
        case .heading(let heading): return apply(block, to: documentText, heading: heading)
        }
    }

    // MARK: - Heading callout

    /// Parse the `> [!props]` callout under `heading`, or an empty block if none.
    public static func read(from documentText: String, heading: HeadingNode) -> PropsBlock {
        let ns = documentText as NSString
        guard let range = locateBlock(ns, afterHeadingLineEndingAt: NSMaxRange(heading.headingRange)) else {
            return PropsBlock()
        }
        return PropsBlock.parseCallout(ns.substring(with: range))
    }

    /// Insert, replace, or remove the `> [!props]` callout under `heading`.
    /// A block that ``PropsBlock/isEmpty`` removes the callout entirely.
    public static func apply(_ block: PropsBlock, to documentText: String, heading: HeadingNode) -> String {
        let ns = documentText as NSString
        let headingLineEnd = NSMaxRange(heading.headingRange)
        let core = block.calloutText()
        let existing = locateBlock(ns, afterHeadingLineEndingAt: headingLineEnd)

        let result: String
        if let existing {
            if let core {
                let mutable = NSMutableString(string: documentText)
                mutable.replaceCharacters(in: existing, with: core)
                result = String(mutable)
            } else {
                result = removeBlock(ns, contentRange: existing)
            }
        } else if let core {
            result = insertBlock(ns, core: core, headingLineEnd: headingLineEnd)
        } else {
            return documentText
        }
        return reconcileTrailingNewline(original: documentText, result: result)
    }

    // MARK: - Frontmatter (document root)

    /// System frontmatter keys the inspector never surfaces or rewrites.
    private static let systemKeys: [String] = ["id", "created", "modified", "title"]

    /// Read `tags`/`status`/`scheduled`/`due` plus any non-system custom keys
    /// out of the document's YAML frontmatter.
    public static func readFrontmatter(from documentText: String) -> PropsBlock {
        let parser = MarkdownParser()
        let (frontmatter, _) = parser.parseFrontmatter(from: documentText)
        var block = PropsBlock()
        block.tags = parser.parseTags(from: frontmatter)
        if let raw = frontmatter["status"] { block.status = PropsStatus(rawValue: raw.lowercased()) }
        block.scheduled = frontmatter["scheduled"]
        block.due = frontmatter["due"]

        let hidden = Set(systemKeys + Array(PropsBlock.reservedKeys))
        block.custom = frontmatter
            .filter { !hidden.contains($0.key.lowercased()) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { PropsField(key: $0.key, value: $0.value) }
        return block
    }

    /// Write `block` into the document's YAML frontmatter, preserving system
    /// keys (id/created/modified/title) and their order, replacing the managed
    /// keys, and creating a frontmatter block if the document has none.
    public static func applyToFrontmatter(_ block: PropsBlock, documentText: String) -> String {
        let existing = extractFrontmatter(documentText)
        let systemLines = existing?.lines.filter { line in
            guard let key = frontmatterKey(of: line) else { return false }
            return systemKeys.contains(key.lowercased())
        } ?? []

        let managedLines = frontmatterManagedLines(for: block)
        let newFieldLines = systemLines + managedLines

        // Nothing to write and no frontmatter to normalize → leave untouched.
        if newFieldLines.isEmpty, existing == nil { return documentText }

        let header = (["---"] + newFieldLines + ["---"]).joined(separator: "\n")

        if let existing {
            // Splice the new header in place of the old, keeping the body verbatim.
            let ns = documentText as NSString
            let body = ns.substring(from: existing.length)
            return header + body
        }
        // No frontmatter yet: prepend, separated from the body by a blank line.
        if documentText.isEmpty { return header + "\n" }
        return header + "\n\n" + documentText
    }

    /// The `tags`/`status`/`scheduled`/`due`/custom lines in `key: value` YAML
    /// form (tags bracketed), in stable order.
    private static func frontmatterManagedLines(for block: PropsBlock) -> [String] {
        var lines: [String] = []
        let readBack = PropsBlock.parseCallout(block.calloutText() ?? "")
        if !readBack.tags.isEmpty { lines.append("tags: [\(readBack.tags.joined(separator: ", "))]") }
        if let status = readBack.status { lines.append("status: \(status.rawValue)") }
        if let scheduled = readBack.scheduled { lines.append("scheduled: \(scheduled)") }
        if let due = readBack.due { lines.append("due: \(due)") }
        for field in readBack.custom { lines.append("\(field.key): \(field.value)") }
        return lines
    }

    // MARK: - Frontmatter helpers

    private struct Frontmatter {
        /// The field lines between the `---` fences (fences excluded).
        let lines: [String]
        /// UTF-16 length of the frontmatter up to (and including) the closing
        /// `---`, but **excluding** the closing fence's newline — so the body
        /// substring keeps that terminator and any blank line after it.
        let length: Int
    }

    /// Locate and split the leading `---` … `---` frontmatter, or `nil`.
    private static func extractFrontmatter(_ documentText: String) -> Frontmatter? {
        let ns = documentText as NSString
        guard ns.length > 0 else { return nil }
        var fieldLines: [String] = []
        var lineStart = 0
        var index = 0
        var closingContentsEnd: Int?
        var sawOpening = false

        while lineStart < ns.length {
            var start = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let content = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if index == 0 {
                guard trimmed == "---" else { return nil }
                sawOpening = true
            } else if trimmed == "---" {
                closingContentsEnd = contentsEnd
                break
            } else {
                fieldLines.append(content)
            }
            lineStart = lineEnd
            index += 1
        }

        guard sawOpening, let end = closingContentsEnd else { return nil }
        return Frontmatter(lines: fieldLines, length: end)
    }

    /// The key of a `key: value` frontmatter line, or `nil` if it has no colon.
    private static func frontmatterKey(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    // MARK: - Callout location

    /// Find an existing `> [!props]` callout that is the first non-blank content
    /// after the heading line ending at `headingLineEnd`. Returns the callout's
    /// UTF-16 content range (its `>` lines, excluding the trailing newline), or
    /// `nil` when no such callout leads the heading's body.
    private static func locateBlock(_ ns: NSString, afterHeadingLineEndingAt headingLineEnd: Int) -> NSRange? {
        // The char at `headingLineEnd` is the heading's terminating newline (or
        // end of text). Nothing can follow a heading that ends the document.
        guard headingLineEnd < ns.length else { return nil }
        var cursor = headingLineEnd + 1

        var blockStart: Int?
        var blockEnd: Int?
        while cursor < ns.length {
            var start = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            let content = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if blockStart == nil {
                if trimmed.isEmpty {
                    cursor = lineEnd    // skip blank lines before the callout
                    continue
                }
                // First non-blank line must open a `[!props]` callout.
                guard isPropsHeader(trimmed) else { return nil }
                blockStart = start
                blockEnd = contentsEnd
            } else {
                // Extend across the contiguous blockquote (`>` lines).
                guard trimmed.hasPrefix(">") else { break }
                blockEnd = contentsEnd
            }
            cursor = lineEnd
        }

        guard let blockStart, let blockEnd else { return nil }
        return NSRange(location: blockStart, length: blockEnd - blockStart)
    }

    /// Whether a trimmed line opens a props callout: `> [!props]` (case-
    /// insensitive, optional `+`/`-` fold marker and title).
    private static func isPropsHeader(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix(">") else { return false }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        return rest.lowercased().hasPrefix("[!props]")
    }

    // MARK: - Insert / remove

    /// Insert `core` (a callout without trailing newline) directly under the
    /// heading line, separated from any following body by exactly one blank line
    /// so the blockquote can't lazily absorb the next paragraph.
    private static func insertBlock(_ ns: NSString, core: String, headingLineEnd: Int) -> String {
        // Heading is the document's final line (no trailing newline).
        guard headingLineEnd < ns.length else {
            return (ns as String) + "\n" + core
        }
        let insertAt = headingLineEnd + 1               // past the heading's newline
        let before = ns.substring(to: insertAt)          // ends with the heading's newline
        var after = Substring(ns.substring(from: insertAt))
        while after.first == "\n" { after = after.dropFirst() }
        if after.isEmpty {
            return before + core
        }
        return before + core + "\n\n" + String(after)
    }

    /// Remove the callout at `contentRange` along with its trailing newline, and
    /// collapse the blank-line seam left behind so the heading doesn't grow a gap.
    private static func removeBlock(_ ns: NSString, contentRange: NSRange) -> String {
        var removal = contentRange
        let afterContent = NSMaxRange(contentRange)
        if afterContent < ns.length, ns.character(at: afterContent) == unichar(10) {
            removal = NSRange(location: contentRange.location, length: contentRange.length + 1)
        }
        let mutable = NSMutableString(string: ns)
        mutable.deleteCharacters(in: removal)
        return collapseBlankRun(String(mutable), around: removal.location)
    }

    /// Collapse a run of 3+ newlines around `index` (the deletion seam) to two.
    private static func collapseBlankRun(_ text: String, around index: Int) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return text }
        let lower = max(0, index - 2)
        let upper = min(ns.length, index + 2)
        let window = ns.substring(with: NSRange(location: lower, length: upper - lower))
        guard window.contains("\n\n\n") else { return text }
        let collapsed = window.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: lower, length: upper - lower), with: collapsed)
        return String(mutable)
    }

    /// Keep the document's original trailing-newline state: restore a single
    /// terminating newline when the edit dropped one, but never add a spurious
    /// one where the source had none.
    private static func reconcileTrailingNewline(original: String, result: String) -> String {
        if original.hasSuffix("\n"), !result.hasSuffix("\n") { return result + "\n" }
        return result
    }
}
