import Foundation

// MARK: - Tier

/// Which extraction tier produced a ``WebContent``. Ordered cheapest/most
/// private first. The three-tier ladder is described in
/// ``WebContentFetcher`` and enforced by ``WebFetchTierPolicy``.
public enum WebFetchTier: String, Sendable, Codable, Equatable, CaseIterable {
    /// Tier 1 — offline `URLSession` + SwiftSoup Readability-style scoring.
    /// The default: fast, no JS rendering, nothing leaves the device.
    case readability
    /// Tier 2 — an invisible `WKWebView` runs Mozilla's Readability.js after
    /// the page's own JavaScript renders. Local fallback for JS-heavy pages.
    case headlessBrowser
    /// Tier 3 — the remote Jina Reader API (`r.jina.ai`). Opt-in only: the URL
    /// leaves the device, so it is gated on explicit per-domain consent.
    case jinaReader
    /// Not part of the offline/browser/Jina ladder — content extracted from a
    /// PDF via PDFKit (see ``PDFIngestExtracting``, ``PDFSummaryRenderer``).
    case pdf
    /// Not part of the offline/browser/Jina ladder — content built from a
    /// fetched video transcript (see ``VideoTranscriptProviding``,
    /// ``VideoSummaryRenderer``).
    case videoTranscript

    /// Human-readable label for chat surfaces and logs.
    public var displayName: String {
        switch self {
        case .readability: return "Readability"
        case .headlessBrowser: return "Headless browser"
        case .jinaReader: return "Jina Reader"
        case .pdf: return "PDF"
        case .videoTranscript: return "Video transcript"
        }
    }
}

// MARK: - Heading

/// One heading (h1–h3) extracted from fetched web content, with a stable
/// anchor id for offline anchor rendering and deep-linking. Anchor ids are
/// either the source element's own `id` attribute (preserved) or a generated
/// slug (see ``WebSlug``); ``WebHeadings/build(from:)`` guarantees uniqueness.
public struct WebHeading: Sendable, Equatable, Codable {
    /// ATX-equivalent level, 1 (`#`) through 3 (`###`).
    public let level: Int
    /// The heading's visible text, trimmed.
    public let text: String
    /// A URL-fragment-safe, document-unique anchor id.
    public let anchorID: String

    public init(level: Int, text: String, anchorID: String) {
        self.level = level
        self.text = text
        self.anchorID = anchorID
    }
}

// MARK: - Content

/// The structured, cleaned output of fetching a web page: reader-mode markdown
/// plus the metadata downstream summarization and offline rendering need. A
/// pure Core value type — the Infra tiers produce it, the Core `web_fetch`
/// tool and summary prompts consume it.
public struct WebContent: Sendable, Equatable, Codable {
    /// The article title (from `<title>`, `og:title`, or the top heading).
    public let title: String
    /// The author line, if one was found (meta author, `rel=author`, byline).
    public let byline: String?
    /// The reader-mode article body as markdown.
    public let contentMarkdown: String
    /// The h1–h3 outline with anchor ids, in document order.
    public let headings: [WebHeading]
    /// When the fetch/extraction completed.
    public let extractedAt: Date
    /// Which tier produced this content.
    public let tier: WebFetchTier
    /// The URL that was requested.
    public let sourceURL: URL
    /// The page's canonical URL (`<link rel=canonical>` / `og:url`), if present
    /// and different from ``sourceURL``.
    public let canonicalURL: URL?

    public init(
        title: String,
        byline: String?,
        contentMarkdown: String,
        headings: [WebHeading],
        extractedAt: Date,
        tier: WebFetchTier,
        sourceURL: URL,
        canonicalURL: URL?
    ) {
        self.title = title
        self.byline = byline
        self.contentMarkdown = contentMarkdown
        self.headings = headings
        self.extractedAt = extractedAt
        self.tier = tier
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
    }
}
