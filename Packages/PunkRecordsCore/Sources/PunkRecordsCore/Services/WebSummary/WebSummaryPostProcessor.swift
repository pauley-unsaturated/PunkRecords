import Foundation

/// Parses the LLM's structured JSON response to the ``WebSummaryPrompt`` and
/// renders it into the final 4-section markdown summary body with inline
/// citation links.
///
/// A pure, stateless namespace (like ``WebFetchTool/format(_:maxContentCharacters:)``)
/// — no actor, no I/O, no LLM calls. ``process(rawResponse:content:)`` is the
/// single entry point PUNK-ddq's note writer needs; ``parse(_:)`` and
/// ``render(payload:content:)`` are exposed separately so tests (and future
/// callers that already have a decoded payload) can exercise each half.
///
/// **Determinism**: for a fixed `(payload, content)`, ``render(payload:content:)``
/// always produces byte-identical markdown — footnote numbers are assigned by
/// first-appearance order over the DECODED payload, not by whatever
/// `citation_index` the model happened to emit, and duplicate citations
/// (same `supportingText` + `nearestHeadingAnchor`) collapse to one footnote.
/// The only source of run-to-run variance is the LLM's own output.
///
/// **Quote length policy**: `supporting_text` for a quote longer than
/// ``WebSummaryPrompt/maxQuoteWords`` is TRUNCATED (not rejected) to its first
/// `maxQuoteWords` words, with a trailing "…" in the *displayed* quote. The
/// (untruncated-of-punctuation) truncated text is also what's used to resolve
/// the citation link, which stays valid: truncating a verbatim match from the
/// end of a string that's already a substring of the page text yields another
/// substring of the page text.
public enum WebSummaryPostProcessor {
    /// The resolved link for one citation, plus whether resolution actually
    /// succeeded (vs. falling back to the bare page URL).
    public struct CitationLinkOutcome: Sendable, Equatable {
        /// The link to render — the anchored deep-link when resolved, the
        /// bare page/source URL otherwise.
        public let url: URL
        public let isResolved: Bool

        public init(url: URL, isResolved: Bool) {
            self.url = url
            self.isResolved = isResolved
        }
    }

    /// Strategy for turning a citation's `supportingText` into a clickable
    /// link. The default (used when ``render(payload:content:citationLinkResolver:)``
    /// is given `nil`) resolves against `content.contentMarkdown` via
    /// ``TextFragmentBuilder`` — a `#:~:text=` scroll-to-text deep link.
    /// PUNK-zup's video/PDF routes plug in their own resolver instead
    /// (``VideoSummaryRenderer/citationLinkResolver(transcript:videoURL:)``,
    /// ``PDFSummaryRenderer/citationLinkResolver(pages:pdfURL:)``) so the SAME
    /// prompt/parse/render pipeline can cite a transcript timestamp or a PDF
    /// page number instead of a text fragment, without duplicating the
    /// section-rendering/footnote/dedup logic below.
    public typealias CitationLinkResolver = @Sendable (WebSummaryCitation) -> CitationLinkOutcome

    /// Failure modes for ``parse(_:)``.
    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The response was empty (or whitespace/fence-only) after stripping
        /// a wrapping code fence.
        case emptyResponse
        /// The (fence-stripped) text isn't valid JSON, or doesn't decode to
        /// ``WebSummaryPayload``'s shape. Carries a human-readable diagnostic.
        case invalidJSON(underlying: String)

        public var description: String {
            switch self {
            case .emptyResponse:
                return "The model returned an empty response; expected a JSON summary payload."
            case .invalidJSON(let underlying):
                return "Could not parse the model's response as the expected JSON summary payload: \(underlying)"
            }
        }
    }

    /// The rendered summary plus enough of the intermediate state for a
    /// caller to store/inspect: the decoded payload (for validation or
    /// frontmatter derivation) and how many citations couldn't be resolved to
    /// a page location.
    public struct Result: Sendable, Equatable {
        public let markdown: String
        public let payload: WebSummaryPayload
        /// Citations whose `supportingText` didn't resolve uniquely against
        /// `content.contentMarkdown` (see ``TextFragmentBuilder``). These are
        /// still rendered — pointing at the bare page URL — but flagged here
        /// so a caller can surface a warning.
        public let unresolvedCitationCount: Int
    }

    // MARK: - Entry point

    /// Parse `rawResponse` and render it against `content` in one call.
    /// - Parameter citationLinkResolver: see ``CitationLinkResolver``; `nil`
    ///   uses the default `#:~:text=` text-fragment resolver.
    public static func process(
        rawResponse: String,
        content: WebContent,
        citationLinkResolver: CitationLinkResolver? = nil
    ) throws -> Result {
        let payload = try parse(rawResponse)
        let rendered = render(payload: payload, content: content, citationLinkResolver: citationLinkResolver)
        return Result(
            markdown: rendered.markdown,
            payload: payload,
            unresolvedCitationCount: rendered.unresolvedCitationCount
        )
    }

    // MARK: - Parse

    /// Decode the model's raw text response into a ``WebSummaryPayload``.
    /// Tolerates a response wrapped in a ```` ```json ... ``` ```` fence even
    /// though the prompt asks the model not to do that, since some providers
    /// do it anyway.
    public static func parse(_ raw: String) throws -> WebSummaryPayload {
        let jsonText = extractJSON(from: raw)
        guard !jsonText.isEmpty else { throw ParseError.emptyResponse }
        guard let data = jsonText.data(using: .utf8) else {
            throw ParseError.invalidJSON(underlying: "response was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(WebSummaryPayload.self, from: data)
        } catch {
            throw ParseError.invalidJSON(underlying: String(describing: error))
        }
    }

    /// Strip a leading/trailing ``` fence (with an optional `json` language
    /// tag) and surrounding whitespace.
    static func extractJSON(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            text = ""
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Render

    /// One citation with its assigned (deterministic, first-appearance)
    /// footnote number and resolved link.
    private struct AssignedCitation {
        let number: Int
        let citation: WebSummaryCitation
        let link: CitationLinkOutcome
    }

    /// The default resolver: a `#:~:text=` scroll-to-text deep link built via
    /// ``TextFragmentBuilder`` against `pageText`, falling back to the bare
    /// `pageURL` when the citation can't be resolved uniquely.
    static func defaultCitationLinkResolver(pageURL: URL, pageText: String) -> CitationLinkResolver {
        { citation in
            switch TextFragmentBuilder.build(supportingText: citation.supportingText, pageText: pageText) {
            case .unique(let fragment), .disambiguated(let fragment):
                let url = URL(string: baseURLString(pageURL) + "#:~:" + fragment) ?? pageURL
                return CitationLinkOutcome(url: url, isResolved: true)
            case .notFound, .ambiguous:
                let bareURL = URL(string: baseURLString(pageURL)) ?? pageURL
                return CitationLinkOutcome(url: bareURL, isResolved: false)
            }
        }
    }

    /// Render a decoded payload against the page it was summarized from.
    /// - Parameter citationLinkResolver: see ``CitationLinkResolver``; `nil`
    ///   uses ``defaultCitationLinkResolver(pageURL:pageText:)``.
    public static func render(
        payload: WebSummaryPayload,
        content: WebContent,
        citationLinkResolver: CitationLinkResolver? = nil
    ) -> (markdown: String, unresolvedCitationCount: Int) {
        let pageText = content.contentMarkdown
        let pageURL = content.canonicalURL ?? content.sourceURL
        let resolveLink = citationLinkResolver ?? defaultCitationLinkResolver(pageURL: pageURL, pageText: pageText)

        var assignedByKey: [String: AssignedCitation] = [:]
        var orderedAssigned: [AssignedCitation] = []

        func assign(_ citation: WebSummaryCitation) -> AssignedCitation {
            let key = citationKey(citation)
            if let existing = assignedByKey[key] { return existing }
            let link = resolveLink(citation)
            let assigned = AssignedCitation(number: orderedAssigned.count + 1, citation: citation, link: link)
            assignedByKey[key] = assigned
            orderedAssigned.append(assigned)
            return assigned
        }

        let keyPointLines = payload.keyPoints.map { point -> String in
            let assigned = assign(point.citation)
            return "- \(point.text) [\(superscript(assigned.number))]"
        }

        let quoteLines = payload.quotes.map { quote -> String in
            let (matchText, displayText, _) = truncatedQuote(quote.citation.supportingText)
            let truncatedCitation = WebSummaryCitation(
                citationIndex: quote.citation.citationIndex,
                supportingText: matchText,
                nearestHeadingAnchor: quote.citation.nearestHeadingAnchor
            )
            let assigned = assign(truncatedCitation)
            return "> \"\(displayText)\" [\(superscript(assigned.number))]"
        }

        let whyItMattersLines = (payload.whyItMatters ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { "- \($0)" }

        let sourceLines = orderedAssigned.map { assigned -> String in
            let headingText = assigned.citation.nearestHeadingAnchor.flatMap { anchor in
                content.headings.first(where: { $0.anchorID == anchor })?.text
            } ?? "Source"
            let preview = previewText(assigned.citation.supportingText)
            return "\(assigned.number). [\(headingText)](\(assigned.link.url.absoluteString)) — \"\(preview)\""
        }

        var sections: [String] = []
        sections.append("## TL;DR\n\n\(payload.tldr.trimmingCharacters(in: .whitespacesAndNewlines))")
        sections.append("## Key Points\n\n" + keyPointLines.joined(separator: "\n"))
        sections.append("## Notable Quotes\n\n" + quoteLines.joined(separator: "\n\n"))
        if !whyItMattersLines.isEmpty {
            sections.append("## Why This Matters\n\n" + whyItMattersLines.joined(separator: "\n"))
        }
        sections.append("## Sources\n\n" + sourceLines.joined(separator: "\n"))

        let markdown = sections.joined(separator: "\n\n") + "\n"
        let unresolvedCount = orderedAssigned.filter { !$0.link.isResolved }.count

        return (markdown, unresolvedCount)
    }

    // MARK: - Private helpers

    private static func citationKey(_ citation: WebSummaryCitation) -> String {
        citation.supportingText + "\u{0}" + (citation.nearestHeadingAnchor ?? "")
    }

    private static let superscriptDigits: [Character: Character] = [
        "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}", "4": "\u{2074}",
        "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}", "8": "\u{2078}", "9": "\u{2079}"
    ]

    /// Render a positive integer as Unicode superscript digits, e.g. `12` → `"¹²"`.
    static func superscript(_ n: Int) -> String {
        String(String(n).compactMap { superscriptDigits[$0] })
    }

    /// Truncate `text` to ``WebSummaryPrompt/maxQuoteWords`` words if longer.
    /// Returns the (possibly truncated) text to use for citation matching,
    /// the text to display (with a trailing "…" when truncated), and whether
    /// truncation occurred.
    static func truncatedQuote(_ text: String) -> (matchText: String, displayText: String, wasTruncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count > WebSummaryPrompt.maxQuoteWords else {
            return (trimmed, trimmed, false)
        }
        let truncated = words.prefix(WebSummaryPrompt.maxQuoteWords).joined(separator: " ")
        return (truncated, truncated + "…", true)
    }

    /// A short single-line preview of `text` for the Sources list, truncated
    /// (with a trailing "…") past `maxLength` characters.
    static func previewText(_ text: String, maxLength: Int = 140) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return trimmed[..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func baseURLString(_ url: URL) -> String {
        let s = url.absoluteString
        guard let hashIndex = s.firstIndex(of: "#") else { return s }
        return String(s[..<hashIndex])
    }
}
