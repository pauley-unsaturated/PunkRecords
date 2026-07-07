import Foundation

/// One point-of-fact citation the LLM attaches to a key point or quote: the
/// verbatim page text it's grounded in, plus the model's own numbering and the
/// nearest heading anchor for readable "Sources" attribution.
///
/// Mirrors the exact JSON tuple documented in PUNK-tlu:
/// `{ citation_index, supporting_text, nearest_heading_anchor }`.
///
/// `citationIndex` is carried through for traceability but the rendered
/// footnote numbers in the final markdown are assigned independently by
/// ``WebSummaryPostProcessor`` — first-appearance order, deduped by
/// `(supportingText, nearestHeadingAnchor)`. Depending on the model's own
/// numbering instead would make re-summarization output less deterministic
/// (the model can renumber identically-meant citations differently across
/// runs even when the *content* it picks is stable).
public struct WebSummaryCitation: Codable, Sendable, Equatable {
    public let citationIndex: Int
    /// A verbatim substring the model claims exists in the fetched page text.
    /// ``TextFragmentBuilder`` resolves this against the page to build (or
    /// fail to build) a scroll-to-text-fragment link.
    public let supportingText: String
    /// The anchor id (see ``WebHeading/anchorID``) of the heading nearest this
    /// citation, or `nil` when none applies.
    public let nearestHeadingAnchor: String?

    private enum CodingKeys: String, CodingKey {
        case citationIndex = "citation_index"
        case supportingText = "supporting_text"
        case nearestHeadingAnchor = "nearest_heading_anchor"
    }

    public init(citationIndex: Int, supportingText: String, nearestHeadingAnchor: String?) {
        self.citationIndex = citationIndex
        self.supportingText = supportingText
        self.nearestHeadingAnchor = nearestHeadingAnchor
    }
}

/// One "Key Points" bullet: a paraphrased point plus the citation that grounds it.
public struct WebSummaryKeyPoint: Codable, Sendable, Equatable {
    /// The point, in the model's own words.
    public let text: String
    public let citation: WebSummaryCitation

    public init(text: String, citation: WebSummaryCitation) {
        self.text = text
        self.citation = citation
    }
}

/// One "Notable Quotes" entry. A quote IS its citation — `citation.supportingText`
/// is the quoted text itself, not a paraphrase pointing at separate quoted text —
/// so the displayed quote and the grounded excerpt can never drift apart.
public struct WebSummaryQuote: Codable, Sendable, Equatable {
    public let citation: WebSummaryCitation

    public init(citation: WebSummaryCitation) {
        self.citation = citation
    }
}

/// The full structured payload the LLM emits as raw JSON per ``WebSummaryPrompt``.
/// ``WebSummaryPostProcessor`` decodes this, then renders it into the final
/// 4-section markdown body with inline citation links.
public struct WebSummaryPayload: Codable, Sendable, Equatable {
    /// 1-3 sentence distillation of the article.
    public let tldr: String
    /// 5-9 bullets, each citing a verbatim excerpt.
    public let keyPoints: [WebSummaryKeyPoint]
    /// 2-4 verbatim excerpts, each ≤30 words.
    public let quotes: [WebSummaryQuote]
    /// Optional short bullets on why the article matters / open questions.
    /// `nil` (or an omitted key) means the model chose to skip this section.
    public let whyItMatters: [String]?

    private enum CodingKeys: String, CodingKey {
        case tldr
        case keyPoints = "key_points"
        case quotes
        case whyItMatters = "why_it_matters"
    }

    public init(tldr: String, keyPoints: [WebSummaryKeyPoint], quotes: [WebSummaryQuote], whyItMatters: [String]?) {
        self.tldr = tldr
        self.keyPoints = keyPoints
        self.quotes = quotes
        self.whyItMatters = whyItMatters
    }
}
