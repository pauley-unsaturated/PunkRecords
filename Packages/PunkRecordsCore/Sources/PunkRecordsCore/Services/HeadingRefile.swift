import Foundation

/// Pure text transforms for moving a heading (and its subtree) between
/// locations — the decision-independent core of refile. No file I/O, no link
/// handling; the editor layer composes these with the repository and any
/// wikilink-update policy. Kept in Core so the move math is unit-testable.
///
/// Ranges are UTF-16 offsets, matching `HeadingOutline.sectionRange`.
public enum HeadingRefile {
    public struct Extraction: Sendable, Equatable {
        /// The source with the section removed and surrounding blank lines tidied.
        public let remainingSource: String
        /// The lifted section text, trailing newlines trimmed to a single `\n`.
        public let section: String

        public init(remainingSource: String, section: String) {
            self.remainingSource = remainingSource
            self.section = section
        }
    }

    /// Lift the section at `sectionRange` out of `source`. Returns nil if the
    /// range is invalid. The removed span is collapsed so the source doesn't
    /// keep a double blank line where the section used to be.
    public static func extract(from source: String, sectionRange: NSRange) -> Extraction? {
        let ns = source as NSString
        guard sectionRange.location >= 0,
              sectionRange.length > 0,
              NSMaxRange(sectionRange) <= ns.length else { return nil }

        let section = ns.substring(with: sectionRange)
        let mutable = NSMutableString(string: source)
        mutable.deleteCharacters(in: sectionRange)
        let remaining = collapseBlankRun(String(mutable), around: sectionRange.location)
        return Extraction(
            remainingSource: remaining,
            section: normalizeSectionTrailing(section)
        )
    }

    /// Insert `section` into `target` at UTF-16 `location`, ensuring the section
    /// is separated from surrounding content by a blank line on each side.
    public static func insert(_ section: String, into target: String, at location: Int) -> String {
        let ns = target as NSString
        let at = min(max(location, 0), ns.length)
        let body = normalizeSectionTrailing(section)

        let before = ns.substring(to: at)
        let after = ns.substring(from: at)

        var piece = ""
        if !before.isEmpty && !before.hasSuffix("\n\n") {
            piece += before.hasSuffix("\n") ? "\n" : "\n\n"
        }
        piece += body
        if !after.isEmpty {
            piece += after.hasPrefix("\n") ? "" : "\n"
        }
        return before + piece + after
    }

    /// Append `section` at the end of the target heading's section, or at the
    /// end of `target` when `parentSection` is nil. Convenience over `insert`.
    public static func append(_ section: String, into target: String, endingAt parentSectionEnd: Int?) -> String {
        let ns = target as NSString
        return insert(section, into: target, at: parentSectionEnd ?? ns.length)
    }

    // MARK: - Helpers

    /// Trim trailing whitespace/newlines from a lifted section, leaving exactly
    /// one terminating newline.
    private static func normalizeSectionTrailing(_ section: String) -> String {
        var s = Substring(section)
        while let last = s.last, last == "\n" || last == " " || last == "\t" || last == "\r" {
            s = s.dropLast()
        }
        return String(s) + "\n"
    }

    /// After a deletion at `index`, collapse a run of 3+ newlines (the seam left
    /// behind) down to two, so removing a section doesn't leave a big gap.
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
}
