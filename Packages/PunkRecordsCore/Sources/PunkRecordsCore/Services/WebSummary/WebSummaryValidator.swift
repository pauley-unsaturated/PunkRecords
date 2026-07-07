import Foundation

/// Structural validation for a decoded ``WebSummaryPayload``, run against the
/// ``WebContent`` it was summarized from. Pure and deterministic — no LLM
/// calls, no I/O.
///
/// Checks the shape ``WebSummaryPrompt`` asks for and every citation's
/// groundedness: presence/length bounds on the three required sections
/// (TL;DR, Key Points, Notable Quotes), and that every citation's
/// `supportingText` resolves to a unique location on the source page (see
/// ``TextFragmentBuilder``). "Why This Matters" is optional per the prompt, so
/// its absence is never an issue — only a present-but-empty array is flagged,
/// since that's a malformed response (the model should have omitted the key
/// entirely, or used `null`, to signal "nothing to add").
///
/// Quote word-count is deliberately NOT checked here: ``WebSummaryPostProcessor``
/// truncates over-length quotes rather than rejecting them, so an over-length
/// `supporting_text` is a rendering concern, not a structural-validity one.
public enum WebSummaryValidator {
    /// One structural problem found in a payload.
    public enum Issue: Sendable, Equatable {
        case missingTLDR
        case keyPointCountOutOfRange(count: Int)
        case keyPointMissingCitation(index: Int)
        case quoteCountOutOfRange(count: Int)
        case quoteMissingCitation(index: Int)
        case emptyWhyItMatters
        case citationUnresolved(supportingText: String, reason: UnresolvedReason)

        public enum UnresolvedReason: Sendable, Equatable {
            /// `supportingText` does not occur anywhere in the page text.
            case notFoundInSource
            /// `supportingText` occurs more than once and couldn't be
            /// disambiguated with prefix/suffix context.
            case ambiguousInSource
        }
    }

    /// All structural problems found in `payload` relative to `content`. Empty
    /// means the payload is structurally valid (see ``isValid(payload:content:)``).
    public static func validate(payload: WebSummaryPayload, content: WebContent) -> [Issue] {
        var issues: [Issue] = []

        if payload.tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingTLDR)
        }

        let keyPointCount = payload.keyPoints.count
        if keyPointCount < WebSummaryPrompt.minKeyPoints || keyPointCount > WebSummaryPrompt.maxKeyPoints {
            issues.append(.keyPointCountOutOfRange(count: keyPointCount))
        }
        for (index, point) in payload.keyPoints.enumerated()
        where point.citation.supportingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.keyPointMissingCitation(index: index))
        }

        let quoteCount = payload.quotes.count
        if quoteCount < WebSummaryPrompt.minQuotes || quoteCount > WebSummaryPrompt.maxQuotes {
            issues.append(.quoteCountOutOfRange(count: quoteCount))
        }
        for (index, quote) in payload.quotes.enumerated()
        where quote.citation.supportingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.quoteMissingCitation(index: index))
        }

        if let whyItMatters = payload.whyItMatters, whyItMatters.isEmpty {
            issues.append(.emptyWhyItMatters)
        }

        let pageText = content.contentMarkdown
        let allCitations = payload.keyPoints.map(\.citation) + payload.quotes.map(\.citation)
        for citation in allCitations {
            switch TextFragmentBuilder.build(supportingText: citation.supportingText, pageText: pageText) {
            case .unique, .disambiguated:
                continue
            case .notFound:
                issues.append(.citationUnresolved(supportingText: citation.supportingText, reason: .notFoundInSource))
            case .ambiguous:
                issues.append(.citationUnresolved(supportingText: citation.supportingText, reason: .ambiguousInSource))
            }
        }

        return issues
    }

    /// Whether `payload` has no structural issues relative to `content`.
    public static func isValid(payload: WebSummaryPayload, content: WebContent) -> Bool {
        validate(payload: payload, content: content).isEmpty
    }
}
