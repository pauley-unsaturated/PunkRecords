import Foundation

// MARK: - Snippet highlighting

/// Pure helpers for turning the search index's marked-up excerpt into a plain
/// snippet plus the ranges to highlight. The FTS5 index already produces
/// snippets — it wraps matched terms in `<mark>…</mark>` delimiters (see
/// `SQLiteSearchIndex.search`'s `snippet(...)` call). We parse those delimiters
/// here rather than recomputing snippets from raw document text, so the search
/// UI highlights exactly the terms the index scored on.
///
/// Lives in Core so the SwiftUI row stays a thin shell over tested logic.
public enum SearchSnippet {
    /// Delimiters the FTS index wraps around matched terms in its snippet output.
    public static let openMarker = "<mark>"
    public static let closeMarker = "</mark>"

    /// One run of snippet text, flagged as a matched term or not. Handy for the
    /// view, which builds a `Text` by concatenating styled runs.
    public struct Segment: Sendable, Equatable {
        public let text: String
        public let isHighlighted: Bool

        public init(text: String, isHighlighted: Bool) {
            self.text = text
            self.isHighlighted = isHighlighted
        }
    }

    /// A plain snippet plus the ranges (into `text`) that were delimited as
    /// matched terms.
    public struct Highlighted: Sendable, Equatable {
        public let text: String
        public let highlightRanges: [Range<String.Index>]

        public init(text: String, highlightRanges: [Range<String.Index>]) {
            self.text = text
            self.highlightRanges = highlightRanges
        }

        public var isEmpty: Bool { text.isEmpty }

        /// The snippet split into alternating plain / highlighted runs.
        public var segments: [Segment] {
            SearchSnippet.segments(text: text, ranges: highlightRanges)
        }
    }

    /// Parse a marked-up snippet (matched terms wrapped in `open`/`close`
    /// delimiters) into plain text plus the ranges those delimiters spanned.
    ///
    /// Degrades gracefully on malformed input: text with no markers returns
    /// verbatim with no highlights; a dangling open marker highlights through to
    /// end-of-text. Real FTS5 output is always balanced, so those paths are
    /// belt-and-suspenders.
    public static func parse(
        marked: String,
        open: String = openMarker,
        close: String = closeMarker
    ) -> Highlighted {
        guard !open.isEmpty, !close.isEmpty else {
            return Highlighted(text: marked, highlightRanges: [])
        }

        var plain = ""
        // Character offsets of highlighted runs, resolved to String.Index only
        // after the full plain string exists (appending invalidates indices).
        var runs: [(start: Int, length: Int)] = []
        var charOffset = 0
        var scanner = Substring(marked)
        var inHighlight = false

        while !scanner.isEmpty {
            let token = inHighlight ? close : open
            if let tokenRange = scanner.range(of: token) {
                let chunk = scanner[scanner.startIndex..<tokenRange.lowerBound]
                let count = chunk.count
                if count > 0 {
                    if inHighlight { runs.append((charOffset, count)) }
                    plain += chunk
                    charOffset += count
                }
                scanner = scanner[tokenRange.upperBound...]
                inHighlight.toggle()
            } else {
                let count = scanner.count
                if count > 0 {
                    if inHighlight { runs.append((charOffset, count)) }
                    plain += scanner
                    charOffset += count
                }
                break
            }
        }

        var ranges: [Range<String.Index>] = []
        ranges.reserveCapacity(runs.count)
        for run in runs where run.length > 0 {
            let lower = plain.index(plain.startIndex, offsetBy: run.start)
            let upper = plain.index(lower, offsetBy: run.length)
            ranges.append(lower..<upper)
        }
        return Highlighted(text: plain, highlightRanges: ranges)
    }

    /// Split `text` into alternating plain / highlighted runs given the ranges
    /// to highlight. Ranges are sorted and clamped defensively so overlapping or
    /// out-of-order input can't produce a malformed segmentation.
    public static func segments(
        text: String,
        ranges: [Range<String.Index>]
    ) -> [Segment] {
        guard !ranges.isEmpty else {
            return text.isEmpty ? [] : [Segment(text: text, isHighlighted: false)]
        }

        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var segments: [Segment] = []
        var cursor = text.startIndex

        for range in sorted {
            let lower = Swift.max(range.lowerBound, cursor)
            let upper = Swift.max(lower, range.upperBound)
            if cursor < lower {
                segments.append(Segment(text: String(text[cursor..<lower]), isHighlighted: false))
            }
            if lower < upper {
                segments.append(Segment(text: String(text[lower..<upper]), isHighlighted: true))
                cursor = upper
            }
        }
        if cursor < text.endIndex {
            segments.append(Segment(text: String(text[cursor...]), isHighlighted: false))
        }
        return segments
    }
}

// MARK: - Display model

/// A search hit shaped for the vault-wide search UI: a stable identity, the
/// note's title and path, and a highlighted snippet. Built from a `SearchResult`
/// by ``VaultSearchDisplay/items(from:)`` so the view never touches the raw
/// index shape.
public struct SearchResultDisplayItem: Identifiable, Sendable, Equatable {
    public let documentID: DocumentID
    public let path: RelativePath
    public let title: String
    /// Snippet plain text (markers stripped). Empty when the hit came only from
    /// metadata filters (`tag:` / `title:`) with no body excerpt to show.
    public let snippet: String
    /// Ranges into `snippet` to highlight (the matched terms).
    public let highlightRanges: [Range<String.Index>]
    public let score: Float

    public init(
        documentID: DocumentID,
        path: RelativePath,
        title: String,
        snippet: String,
        highlightRanges: [Range<String.Index>],
        score: Float
    ) {
        self.documentID = documentID
        self.path = path
        self.title = title
        self.snippet = snippet
        self.highlightRanges = highlightRanges
        self.score = score
    }

    /// Path is the stable selection/navigation key: document ids can collide
    /// across notes with duplicate frontmatter, but a path is unique on disk.
    /// This mirrors how Quick Open opens a note.
    public var id: RelativePath { path }

    public var hasSnippet: Bool { !snippet.isEmpty }

    /// The snippet split into alternating plain / highlighted runs for the view.
    public var snippetSegments: [SearchSnippet.Segment] {
        SearchSnippet.segments(text: snippet, ranges: highlightRanges)
    }

    /// The folder the note lives in (vault root shown as "/"), for a dim path
    /// caption below the title.
    public var folder: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "/" : folder
    }
}

/// Pure display + navigation logic for the vault-wide search UI. The view binds
/// to these so its behavior is unit-tested, mirroring `QuickOpenMatcher`.
public enum VaultSearchDisplay {
    /// Map raw search results into display items, preserving the index's order
    /// (BM25 relevance). A 1:1, order-preserving mapping — the UI shows exactly
    /// what the shared `SearchService` returned, in the same order the agent's
    /// `vault_search` tool sees.
    public static func items(from results: [SearchResult]) -> [SearchResultDisplayItem] {
        results.map { result in
            let highlighted = SearchSnippet.parse(marked: result.excerpt)
            let title = result.title.isEmpty ? Self.fallbackTitle(for: result.path) : result.title
            return SearchResultDisplayItem(
                documentID: result.documentID,
                path: result.path,
                title: title,
                snippet: highlighted.text,
                highlightRanges: highlighted.highlightRanges,
                score: result.score
            )
        }
    }

    /// Clamp `index` into a valid selection for a list of `count` items.
    /// Returns 0 for an empty list so callers always have a defined selection.
    public static func clampIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Swift.min(Swift.max(0, index), count - 1)
    }

    /// New selection after moving `delta` rows from `index`, clamped to the
    /// list bounds (no wrap-around — matches Quick Open).
    public static func move(selection index: Int, by delta: Int, count: Int) -> Int {
        clampIndex(index + delta, count: count)
    }

    /// Best-effort title when the index row carries none: the note's filename
    /// without its `.md` extension.
    private static func fallbackTitle(for path: RelativePath) -> String {
        let last = (path as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        return stem.isEmpty ? path : stem
    }
}
