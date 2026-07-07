import Foundation

/// Pure fold-range computation for the editor's "Live Preview" marker folding.
///
/// Reports which markdown *delimiter* characters (e.g. the `**` around bold)
/// should render at zero width because the caret is outside their element.
/// Folding is PER-ELEMENT: the caret anywhere inside the whole element —
/// including either delimiter or the content between them — reveals ALL of that
/// element's markers.
///
/// This layer never mutates the source string. It only reports UTF-16 ranges;
/// `MarkerFoldDecorator` applies the `.punkFolded` attribute and
/// `WikilinkPillLayoutManager` renders those characters as null glyphs.
///
/// All ranges use `NSString` (UTF-16) semantics, matching
/// `NSTextView.selectedRange()` and `NSRegularExpression`, so emoji / CJK
/// content offsets line up with the text view and the search index.
///
/// Phase 0 covers inline emphasis (`*`/`_`), strong (`**`/`__`), and inline code
/// (`` ` ``). Wikilink brackets, headings, and links are phase 1 (PUNK-zp1).
/// Delimiter pairing is done with regexes: content may not itself contain the
/// delimiter character, so a bold span with a literal internal asterisk is not
/// folded — an acceptable first cut that mirrors the existing marker-dimming
/// regexes in `HybridUXDecorator`.
public enum MarkerFolding {

    /// One paired inline element: its whole span plus the two delimiter ranges.
    public struct Element: Equatable, Sendable {
        /// The full element including both delimiters (e.g. all of `**bold**`).
        public let whole: NSRange
        /// The opening delimiter (e.g. the leading `**`).
        public let openDelimiter: NSRange
        /// The closing delimiter (e.g. the trailing `**`).
        public let closeDelimiter: NSRange

        public init(whole: NSRange, openDelimiter: NSRange, closeDelimiter: NSRange) {
            self.whole = whole
            self.openDelimiter = openDelimiter
            self.closeDelimiter = closeDelimiter
        }

        /// True when `caret` sits anywhere within the element, inclusive of both
        /// boundaries — caret exactly at the element's start or end reveals the
        /// markers (matches `WikilinkDecorator`'s caret-inside convention).
        public func containsCaret(_ caret: Int) -> Bool {
            caret >= whole.location && caret <= whole.location + whole.length
        }
    }

    // MARK: - Element specs

    private struct Spec {
        let regex: NSRegularExpression
        let openGroup: Int
        let closeGroup: Int
    }

    /// Ordered by precedence: an earlier spec claims a character span so a later
    /// spec cannot also match inside it. Inline code wins over emphasis (an `*`
    /// inside `` `code` `` is not emphasis); strong wins over single-delimiter
    /// emphasis (the inner `*` of `**bold**` is never treated as italic).
    private static let specs: [Spec] = {
        func make(_ pattern: String, open: Int, close: Int) -> Spec? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Spec(regex: regex, openGroup: open, closeGroup: close)
        }
        return [
            // Inline code: `code`
            make(#"(`)([^`\n]+)(`)"#, open: 1, close: 3),
            // Strong: **bold**  __bold__
            make(#"(\*\*)([^*\n]+?)(\*\*)"#, open: 1, close: 3),
            make(#"(__)([^_\n]+?)(__)"#, open: 1, close: 3),
            // Emphasis: *italic*  _italic_  (lone delimiter, not half of a pair).
            make(#"(?<!\*)(\*)(?!\*)([^*\n]+?)(?<!\*)(\*)(?!\*)"#, open: 1, close: 3),
            make(#"(?<!_)(_)(?!_)([^_\n]+?)(?<!_)(_)(?!_)"#, open: 1, close: 3),
        ].compactMap { $0 }
    }()

    // MARK: - Element scanning

    /// All paired inline elements found within `scanRange`, precedence-resolved.
    /// Unbalanced or unterminated markers simply do not match (no `Element` is
    /// produced), so a stray `**` or an unclosed `` ` `` never folds.
    static func elements(in text: NSString, scanRange: NSRange) -> [Element] {
        var claimed: [NSRange] = []
        var result: [Element] = []
        let source = text as String
        for spec in specs {
            spec.regex.enumerateMatches(in: source, range: scanRange) { match, _, _ in
                guard let match else { return }
                let whole = match.range
                guard whole.location != NSNotFound else { return }
                if claimed.contains(where: { NSIntersectionRange($0, whole).length > 0 }) {
                    return
                }
                let open = match.range(at: spec.openGroup)
                let close = match.range(at: spec.closeGroup)
                guard open.location != NSNotFound, close.location != NSNotFound else { return }
                claimed.append(whole)
                result.append(Element(whole: whole, openDelimiter: open, closeDelimiter: close))
            }
        }
        return result
    }

    // MARK: - Fold computation

    /// UTF-16 delimiter ranges that should render at zero width: for every paired
    /// element in `scanRange` whose span does NOT contain `caret`, both the open
    /// and close delimiters. Elements touched by the caret are omitted (their
    /// markers stay visible so the user can edit them).
    public static func foldRanges(in text: NSString, scanRange: NSRange, caret: Int) -> [NSRange] {
        guard text.length > 0, scanRange.length > 0 else { return [] }
        var folds: [NSRange] = []
        for element in elements(in: text, scanRange: scanRange) where !element.containsCaret(caret) {
            folds.append(element.openDelimiter)
            folds.append(element.closeDelimiter)
        }
        return folds
    }

    // MARK: - Scoped invalidation

    /// Paragraph ranges whose fold state changed between two fold sets. Used to
    /// scope glyph/layout invalidation so a caret move never relayouts the whole
    /// document — only the paragraphs that gained or lost a fold are touched.
    ///
    /// `old` and `new` are compared as sets of ranges; every range present in
    /// exactly one of them is expanded to its enclosing paragraph in `text`, and
    /// the resulting paragraphs are merged into a minimal, sorted set.
    public static func invalidationRanges(old: [NSRange], new: [NSRange], in text: NSString) -> [NSRange] {
        let onlyOld = old.filter { o in !new.contains(where: { NSEqualRanges($0, o) }) }
        let onlyNew = new.filter { n in !old.contains(where: { NSEqualRanges($0, n) }) }
        let changed = onlyOld + onlyNew
        guard !changed.isEmpty, text.length > 0 else { return [] }

        var paragraphs: [NSRange] = []
        for range in changed {
            let loc = min(max(range.location, 0), text.length - 1)
            let len = min(max(range.length, 0), text.length - loc)
            let para = text.paragraphRange(for: NSRange(location: loc, length: len))
            paragraphs.append(para)
        }
        return mergeRanges(paragraphs)
    }

    /// Sort and coalesce overlapping or touching ranges into a minimal set.
    static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            let lastEnd = last.location + last.length
            if range.location <= lastEnd {
                let newEnd = max(lastEnd, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
