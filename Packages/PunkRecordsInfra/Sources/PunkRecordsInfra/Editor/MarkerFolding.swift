import Foundation

/// Pure fold-range computation for the editor's "Live Preview" marker folding.
///
/// Reports which markdown *marker* characters (e.g. the `**` around bold, the
/// `# ` prefix of a heading, the `[…](url)` scaffolding of a link) should
/// render at zero width because the caret is outside their element. Folding is
/// PER-ELEMENT: the caret anywhere inside the whole element — including any
/// marker or the content between them — reveals ALL of that element's markers.
///
/// This layer never mutates the source string. It only reports UTF-16 ranges;
/// `LivePreviewDecorator` applies the `.punkFolded` attribute and
/// `WikilinkPillLayoutManager` renders those characters as null glyphs.
///
/// All ranges use `NSString` (UTF-16) semantics, matching
/// `NSTextView.selectedRange()` and `NSRegularExpression`, so emoji / CJK
/// content offsets line up with the text view and the search index.
///
/// Covered element kinds (phase 1, PUNK-zp1): inline emphasis (`*`/`_`), strong
/// (`**`/`__`), strikethrough (`~~`), inline code (`` ` ``), ATX heading hash
/// prefixes (including ONE trailing space), `[[wikilink]]` brackets, and
/// markdown `[text](url)` links (brackets + parens + url fold; only the text
/// stays visible). Nothing folds inside fenced code blocks.
///
/// Pairing is regex-based: content may not itself contain the delimiter
/// character, so e.g. a bold span with a literal internal asterisk is not
/// folded — an acceptable first cut that mirrors the marker-dimming regexes in
/// `HybridUXDecorator`. Known limitation: fence regions are detected within
/// `scanRange` only, so a fence that OPENS above the scanned (visible) region
/// is not seen; `EditorDecorationRange`'s 40-line buffer makes this rare in
/// practice, and the same limitation already applies to every regex-based
/// decoration pass.
public enum MarkerFolding {

    /// One markdown element: its whole span, visible content, and the marker
    /// ranges that fold when the caret is outside.
    public struct Element: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case inlineCode
            case strong
            case emphasis
            case strikethrough
            case heading
            case wikilink
            case link
        }

        public let kind: Kind
        /// The full element (e.g. all of `**bold**`, or a heading's whole line).
        public let whole: NSRange
        /// The visible text (e.g. `bold`, a link's label, a heading's title).
        public let content: NSRange
        /// Marker ranges hidden when the caret is outside `whole`. One range for
        /// headings (`#… ` prefix), two for delimiter pairs; a link's second
        /// marker is the whole `](url)` tail.
        public let markers: [NSRange]

        public init(kind: Kind, whole: NSRange, content: NSRange, markers: [NSRange]) {
            self.kind = kind
            self.whole = whole
            self.content = content
            self.markers = markers
        }

        /// True when `caret` sits anywhere within the element, inclusive of both
        /// boundaries — caret exactly at the element's start or end reveals the
        /// markers (matches `WikilinkDecorator`'s caret-inside convention).
        public func containsCaret(_ caret: Int) -> Bool {
            caret >= whole.location && caret <= whole.location + whole.length
        }
    }

    // MARK: - Inline element specs

    private struct Spec {
        let kind: Element.Kind
        let regex: NSRegularExpression
    }

    /// Ordered by precedence: an earlier spec claims a character span so a later
    /// spec cannot also match inside it. Inline code wins over everything (an
    /// `*` inside `` `code` `` is not emphasis); wikilinks win over markdown
    /// links (`[[x]]` is never a half-link); links win over emphasis so a
    /// styled label survives; strong wins over single-delimiter emphasis. Every
    /// pattern has exactly three capture groups: open marker, content, close
    /// marker.
    private static let specs: [Spec] = {
        func make(_ kind: Element.Kind, _ pattern: String) -> Spec? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Spec(kind: kind, regex: regex)
        }
        return [
            // Inline code: `code`
            make(.inlineCode, #"(`)([^`\n]+)(`)"#),
            // Wikilink: [[target]] / [[target|alias]]
            make(.wikilink, #"(\[\[)([^\]\n]+)(\]\])"#),
            // Markdown link: [text](url) — not an image (![alt](url)).
            make(.link, #"(?<!!)(\[)([^\]\n]+)(\]\([^)\n]*\))"#),
            // Strong: **bold**  __bold__
            make(.strong, #"(\*\*)([^*\n]+?)(\*\*)"#),
            make(.strong, #"(__)([^_\n]+?)(__)"#),
            // Strikethrough: ~~gone~~ (lone pair, not part of a longer tilde run).
            make(.strikethrough, #"(?<!~)(~~)(?!~)([^~\n]+?)(?<!~)(~~)(?!~)"#),
            // Emphasis: *italic*  _italic_  (lone delimiter, not half of a pair).
            make(.emphasis, #"(?<!\*)(\*)(?!\*)([^*\n]+?)(?<!\*)(\*)(?!\*)"#),
            make(.emphasis, #"(?<!_)(_)(?!_)([^_\n]+?)(?<!_)(_)(?!_)"#),
        ].compactMap { $0 }
    }()

    /// ATX heading marker: up to 3 leading spaces, 1-6 hashes, ONE literal
    /// space, and at least one non-space character of title after it. The fold
    /// marker is group 2 — the hashes plus that single trailing space.
    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^( {0,3})(#{1,6} )(?=.*\S)"#,
        options: [.anchorsMatchLines]
    )

    /// A fenced-code delimiter line: up to 3 leading spaces then a run of 3+
    /// backticks or tildes (the opening fence may carry an info string).
    private static let fenceLineRegex = try! NSRegularExpression(
        pattern: #"^ {0,3}(`{3,}|~{3,})"#,
        options: [.anchorsMatchLines]
    )

    // MARK: - Fenced code regions

    /// Regions covered by fenced code blocks within `scanRange`, INCLUDING the
    /// fence delimiter lines. Elements intersecting these regions never fold.
    /// A fence opened by ``` only closes on a backtick fence line (and likewise
    /// for ~~~); an unterminated fence extends to the end of `scanRange`.
    static func fencedCodeRegions(in text: NSString, scanRange: NSRange) -> [NSRange] {
        var regions: [NSRange] = []
        var openStart: Int?
        var openChar: unichar = 0

        fenceLineRegex.enumerateMatches(in: text as String, range: scanRange) { match, _, _ in
            guard let match else { return }
            let fenceChars = match.range(at: 1)
            let char = text.character(at: fenceChars.location)
            let lineRange = text.lineRange(for: match.range)
            if let start = openStart {
                if char == openChar {
                    regions.append(NSRange(location: start, length: lineRange.location + lineRange.length - start))
                    openStart = nil
                }
                // A different fence char inside an open fence is content.
            } else {
                openStart = lineRange.location
                openChar = char
            }
        }
        if let start = openStart {
            let end = scanRange.location + scanRange.length
            regions.append(NSRange(location: start, length: max(0, end - start)))
        }
        return regions
    }

    // MARK: - Element scanning

    /// All foldable elements found within `scanRange`, precedence-resolved and
    /// with fenced code blocks excluded. Unbalanced or unterminated markers
    /// simply do not match (no `Element` is produced), so a stray `**` or an
    /// unclosed `` ` `` never folds.
    static func elements(in text: NSString, scanRange: NSRange) -> [Element] {
        let fences = fencedCodeRegions(in: text, scanRange: scanRange)
        func inFence(_ range: NSRange) -> Bool {
            fences.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var result: [Element] = []

        // Inline pairs, claiming spans in precedence order. Headings do not
        // participate in claiming: their span is the whole line, and inline
        // elements inside a heading's title still fold independently.
        var claimed: [NSRange] = []
        let source = text as String
        for spec in specs {
            spec.regex.enumerateMatches(in: source, range: scanRange) { match, _, _ in
                guard let match else { return }
                let whole = match.range
                guard whole.location != NSNotFound, !inFence(whole) else { return }
                if claimed.contains(where: { NSIntersectionRange($0, whole).length > 0 }) {
                    return
                }
                let open = match.range(at: 1)
                let content = match.range(at: 2)
                let close = match.range(at: 3)
                guard open.location != NSNotFound, close.location != NSNotFound else { return }
                claimed.append(whole)
                result.append(Element(kind: spec.kind, whole: whole, content: content, markers: [open, close]))
            }
        }

        // ATX headings: whole = the heading line (minus its line terminator) so
        // the caret anywhere on the line reveals; marker = hashes + one space.
        headingRegex.enumerateMatches(in: source, range: scanRange) { match, _, _ in
            guard let match else { return }
            let marker = match.range(at: 2)
            guard marker.location != NSNotFound, !inFence(match.range) else { return }
            let line = lineContentRange(in: text, around: match.range)
            let contentStart = marker.location + marker.length
            let content = NSRange(
                location: contentStart,
                length: max(0, line.location + line.length - contentStart)
            )
            result.append(Element(kind: .heading, whole: line, content: content, markers: [marker]))
        }

        return result
    }

    /// The line containing `range`, with any trailing `\n` / `\r\n` excluded so
    /// a caret at the start of the NEXT line counts as outside the element.
    private static func lineContentRange(in text: NSString, around range: NSRange) -> NSRange {
        var line = text.lineRange(for: range)
        while line.length > 0 {
            let last = text.character(at: line.location + line.length - 1)
            if last == 0x0A || last == 0x0D {
                line.length -= 1
            } else {
                break
            }
        }
        return line
    }

    // MARK: - Fold computation

    /// UTF-16 marker ranges that should render at zero width: for every element
    /// in `scanRange` whose span does NOT contain `caret`, all of its markers.
    /// Elements touched by the caret are omitted (their markers stay visible so
    /// the user can edit them).
    public static func foldRanges(in text: NSString, scanRange: NSRange, caret: Int) -> [NSRange] {
        guard text.length > 0, scanRange.length > 0 else { return [] }
        return foldRanges(elements: elements(in: text, scanRange: scanRange), caret: caret)
    }

    /// Fold ranges for an already-computed element list (lets the decorator
    /// scan once and reuse the elements for link styling and hit testing).
    static func foldRanges(elements: [Element], caret: Int) -> [NSRange] {
        var folds: [NSRange] = []
        for element in elements where !element.containsCaret(caret) {
            folds.append(contentsOf: element.markers)
        }
        return folds
    }

    // MARK: - Link hit testing

    /// The URL of the markdown link whose visible label encloses `index`, or
    /// nil if the index isn't on a link label. Modeled on
    /// `WikilinkDecorator.wikilinkTarget(at:in:)`. Image references (`![…](…)`),
    /// links inside inline code spans, and links inside fenced code blocks are
    /// never hits — `elements(in:scanRange:)` already excludes all three.
    public static func linkTarget(at index: Int, in text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for element in elements(in: ns, scanRange: full) where element.kind == .link {
            let label = element.content
            if index >= label.location && index < label.location + label.length {
                // markers[1] is the "](url)" tail; strip the "](" and ")".
                let tail = element.markers[1]
                let urlRange = NSRange(location: tail.location + 2, length: tail.length - 3)
                let url = ns.substring(with: urlRange).trimmingCharacters(in: .whitespaces)
                return url.isEmpty ? nil : url
            }
        }
        return nil
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
