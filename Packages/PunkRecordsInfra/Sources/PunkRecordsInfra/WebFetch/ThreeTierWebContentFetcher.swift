import Foundation
import PunkRecordsCore

/// The concrete ``WebContentFetcher``: walks the three-tier extraction ladder
/// (Readability → headless browser → Jina), caches fetched HTML for offline
/// anchor rendering, and assembles a ``WebContent``. Tier selection is delegated
/// to the pure Core ``WebFetchTierPolicy``; Tier 3 is gated on the injected
/// consent closure (backed by ``WebFetchConsentStore`` in the App).
///
/// A standalone service the `web_fetch` tool wraps, so a future web-search
/// feature (PUNK-e5u) can reuse the same fetcher.
public struct ThreeTierWebContentFetcher: WebContentFetcher {
    private let httpClient: any WebHTTPClient
    private let readability: ReadabilityExtractor
    private let browserExtractor: (any BrowserContentExtracting)?
    private let cache: WebContentCache
    private let jinaEnabled: Bool
    private let jinaConsent: @Sendable (URL) async -> Bool
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    /// Designated initializer. Internal because `browserExtractor` is an
    /// internal seam (`WKWebView` stub in tests); App code uses ``makeDefault``.
    init(
        httpClient: any WebHTTPClient = URLSessionWebHTTPClient(),
        vaultRoot: URL? = nil,
        browserExtractor: (any BrowserContentExtracting)? = nil,
        jinaEnabled: Bool = true,
        jinaConsent: @escaping @Sendable (URL) async -> Bool = { _ in false },
        requestTimeout: TimeInterval = 20,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.readability = ReadabilityExtractor()
        self.browserExtractor = browserExtractor
        self.cache = WebContentCache(vaultRoot: vaultRoot)
        self.jinaEnabled = jinaEnabled
        self.jinaConsent = jinaConsent
        self.requestTimeout = requestTimeout
        self.now = now
    }

    /// Build the production fetcher with a real `WKWebView` Tier 2 extractor.
    /// Must be called on the main actor because `WKWebView` is main-thread-only.
    @MainActor
    public static func makeDefault(
        vaultRoot: URL?,
        jinaEnabled: Bool = true,
        jinaConsent: @escaping @Sendable (URL) async -> Bool = { _ in false },
        requestTimeout: TimeInterval = 20
    ) -> ThreeTierWebContentFetcher {
        ThreeTierWebContentFetcher(
            vaultRoot: vaultRoot,
            browserExtractor: WebKitReadabilityExtractor(timeout: requestTimeout),
            jinaEnabled: jinaEnabled,
            jinaConsent: jinaConsent,
            requestTimeout: requestTimeout
        )
    }

    public func fetch(url: URL) async throws -> WebContent {
        // Tier 1 — download + offline Readability.
        let response = try await httpClient.get(url, headers: Self.browserHeaders, timeout: requestTimeout)
        let html = response.text()
        let finalURL = response.finalURL
        cache.store(html: html, for: url)

        let tier1 = (try? readability.extract(html: html, baseURL: finalURL))
            ?? ExtractedArticle.empty(host: finalURL.host)

        if !WebFetchTierPolicy.shouldEscalateToBrowser(
            tier1CharacterCount: tier1.textLength,
            isProbablyReaderable: true
        ) {
            return build(tier1, tier: .readability, url: url, finalURL: finalURL)
        }

        // Tier 2 — headless browser + Readability.js (if available).
        let tier2 = await runBrowserTier(url: finalURL)
        if let tier2, tier2.textLength >= WebFetchTierPolicy.minReadableContentLength {
            return build(tier2, tier: .headlessBrowser, url: url, finalURL: finalURL)
        }

        // Best offline result so far.
        let (best, bestTier) = pickBest(tier1: tier1, tier2: tier2)

        // Tier 3 — Jina Reader, opt-in only.
        if jinaEnabled, WebFetchTierPolicy.shouldConsiderJina(tier2CharacterCount: best.textLength) {
            if await jinaConsent(url) {
                if let jina = try? await fetchViaJina(url: url) {
                    return build(jina, tier: .jinaReader, url: url, finalURL: finalURL)
                }
            } else if best.textLength == 0 {
                let domain = WebFetchConsentPolicy.consentDomain(for: url)
                    ?? url.host ?? url.absoluteString
                throw WebFetchError.jinaConsentRequired(domain: domain)
            }
        }

        guard best.textLength > 0 else { throw WebFetchError.noReadableContent }
        return build(best, tier: bestTier, url: url, finalURL: finalURL)
    }

    // MARK: - Tiers

    private func runBrowserTier(url: URL) async -> ExtractedArticle? {
        guard let browserExtractor else { return nil }
        guard let result = try? await browserExtractor.extract(url: url) else { return nil }
        return try? ReadabilityResultMapper.map(result, baseURL: url)
    }

    private func fetchViaJina(url: URL) async throws -> ExtractedArticle {
        let endpoint = JinaReader.endpoint(for: url)
        let response = try await httpClient.get(endpoint, headers: JinaReader.requestHeaders, timeout: requestTimeout)
        return JinaReader.parse(response.text(), sourceURL: url)
    }

    // MARK: - Assembly

    private func pickBest(tier1: ExtractedArticle, tier2: ExtractedArticle?) -> (ExtractedArticle, WebFetchTier) {
        guard let tier2 else { return (tier1, .readability) }
        return tier2.textLength >= tier1.textLength ? (tier2, .headlessBrowser) : (tier1, .readability)
    }

    private func build(_ article: ExtractedArticle, tier: WebFetchTier, url: URL, finalURL: URL) -> WebContent {
        let headings = WebHeadings.build(from: article.rawHeadings)
        let canonical = article.canonicalURL ?? (finalURL != url ? finalURL : nil)
        return WebContent(
            title: article.title,
            byline: article.byline,
            contentMarkdown: article.contentMarkdown,
            headings: headings,
            extractedAt: now(),
            tier: tier,
            sourceURL: url,
            canonicalURL: canonical
        )
    }

    // A desktop-Safari-ish header set so sites serve their normal HTML rather
    // than a bot/challenge page.
    private static let browserHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    ]
}

private extension ExtractedArticle {
    static func empty(host: String?) -> ExtractedArticle {
        ExtractedArticle(
            title: host ?? "Untitled",
            byline: nil,
            contentMarkdown: "",
            rawHeadings: [],
            canonicalURL: nil,
            textLength: 0
        )
    }
}
