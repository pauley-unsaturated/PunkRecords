import Foundation

/// Bridges a ``PDFExtractionResult`` (PUNK-zup failure mode #2) into the
/// existing ``WebSummaryPrompt``/``WebSummaryPostProcessor`` pipeline: builds
/// a page-structured ``WebContent`` to prompt against (one synthetic `## Page
/// N` heading per page, so the model's `nearest_heading_anchor` naturally
/// lands on a page), and a ``WebSummaryPostProcessor/CitationLinkResolver``
/// that resolves a citation's `supporting_text` to the page it appears on and
/// emits a `#page=N` deep link (which Safari and Preview both honor) instead
/// of a `#:~:text=` fragment.
public enum PDFSummaryRenderer {
    /// Build the ``WebContent`` to feed ``WebSummaryPrompt/build(content:variant:languageHint:)``:
    /// pages are concatenated as `## Page N\n\n{page text}` blocks so
    /// ``WebHeadings/build(from:)`` (the SAME anchor-assignment logic Tier
    /// 1/2 use) produces one heading per page with anchor id `page-n`.
    /// `tier` is ``WebFetchTier/pdf``.
    public static func makeContent(
        from extraction: PDFExtractionResult,
        sourceURL: URL,
        extractedAt: Date
    ) -> WebContent {
        let rawHeadings = extraction.pages.map {
            WebHeadings.RawHeading(level: 2, text: "Page \($0.pageNumber)", anchorID: nil)
        }
        let headings = WebHeadings.build(from: rawHeadings)
        let markdown = extraction.pages
            .map { "## Page \($0.pageNumber)\n\n\($0.text)" }
            .joined(separator: "\n\n")

        return WebContent(
            title: extraction.title ?? sourceURL.lastPathComponent,
            byline: nil,
            contentMarkdown: markdown,
            headings: headings,
            extractedAt: extractedAt,
            tier: .pdf,
            sourceURL: sourceURL,
            canonicalURL: nil
        )
    }

    /// A ``WebSummaryPostProcessor/CitationLinkResolver`` that resolves a
    /// citation's `supporting_text` to the FIRST page whose text contains it
    /// (whitespace-normalized substring match) and builds a `pdfURL#page=N`
    /// link. Page-level granularity means this never needs
    /// ``TextFragmentBuilder``'s prefix/suffix disambiguation — a phrase
    /// appearing twice on the same page still resolves to that one page.
    /// Falls back to the bare `pdfURL` (unresolved) when `supporting_text`
    /// isn't found on any page.
    public static func citationLinkResolver(
        pages: [PDFPageText],
        pdfURL: URL
    ) -> WebSummaryPostProcessor.CitationLinkResolver {
        { citation in
            guard let page = resolvePage(for: citation.supportingText, pages: pages) else {
                return .init(url: pdfURL, isResolved: false)
            }
            return .init(url: pageLink(base: pdfURL, page: page), isResolved: true)
        }
    }

    // MARK: - Page resolution

    /// The first page number whose text contains `supportingText`, treating
    /// runs of whitespace in `supportingText` as matching any run of
    /// whitespace on the page (mirroring ``TextFragmentBuilder``'s matching
    /// policy, since PDF text extraction — like HTML — can wrap a quote
    /// across a line break).
    static func resolvePage(for supportingText: String, pages: [PDFPageText]) -> Int? {
        let needle = supportingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let pattern = NSRegularExpression.escapedPattern(for: needle)
            .replacingOccurrences(of: "[ \\t\\n\\r]+", with: "\\\\s+", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        for page in pages {
            let range = NSRange(page.text.startIndex..<page.text.endIndex, in: page.text)
            if regex.firstMatch(in: page.text, range: range) != nil {
                return page.pageNumber
            }
        }
        return nil
    }

    // MARK: - Deep link

    static func pageLink(base: URL, page: Int) -> URL {
        URL(string: baseURLString(base) + "#page=\(page)") ?? base
    }

    private static func baseURLString(_ url: URL) -> String {
        let s = url.absoluteString
        guard let hashIndex = s.firstIndex(of: "#") else { return s }
        return String(s[..<hashIndex])
    }
}
