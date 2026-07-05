import Foundation
import PunkRecordsCore

/// Tier-agnostic intermediate produced by an extractor (Tier 1 SwiftSoup, Tier
/// 2 Readability.js mapping, Tier 3 Jina). Carries everything the orchestrator
/// needs to assemble a ``WebContent`` except the tier/URL/timestamp it stamps
/// itself. Keeping this common shape lets every tier flow through one code path
/// and one call to ``WebHeadings/build(from:)``.
struct ExtractedArticle: Sendable, Equatable {
    var title: String
    var byline: String?
    var contentMarkdown: String
    var rawHeadings: [WebHeadings.RawHeading]
    var canonicalURL: URL?

    /// Length of the extracted body text, used by ``WebFetchTierPolicy`` to
    /// decide whether to escalate to the next tier. Defaults to the markdown
    /// length but a tier may set it from the DOM's text content when that is a
    /// better signal (markdown syntax inflates the count).
    var textLength: Int

    init(
        title: String,
        byline: String?,
        contentMarkdown: String,
        rawHeadings: [WebHeadings.RawHeading],
        canonicalURL: URL?,
        textLength: Int? = nil
    ) {
        self.title = title
        self.byline = byline
        self.contentMarkdown = contentMarkdown
        self.rawHeadings = rawHeadings
        self.canonicalURL = canonicalURL
        self.textLength = textLength ?? contentMarkdown.count
    }
}
