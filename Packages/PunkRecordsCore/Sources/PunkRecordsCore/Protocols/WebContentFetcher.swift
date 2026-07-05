import Foundation

/// Turns a URL into cleaned, structured ``WebContent``. The concrete
/// implementation (Infra's `ThreeTierWebContentFetcher`) walks a three-tier
/// extraction ladder — each tier cheaper/more private than the next:
///
///   1. **Readability** — `URLSession` + SwiftSoup Readability-style scoring.
///      Offline, private, fast; the default.
///   2. **Headless browser** — an invisible `WKWebView` runs Mozilla's
///      Readability.js after the page's own JS renders. Used when Tier 1
///      yields too little content (see ``WebFetchTierPolicy``).
///   3. **Jina Reader** — the remote `r.jina.ai` API. Opt-in only, gated on
///      explicit per-domain consent (see ``WebFetchConsentPolicy``) because
///      the URL leaves the device.
///
/// Kept a standalone service (not folded into the `web_fetch` tool) so a
/// future web-search feature can reuse the same fetcher — see PUNK-e5u.
public protocol WebContentFetcher: Sendable {
    /// Fetch and extract structured content for `url`.
    /// - Throws: ``WebFetchError`` when every eligible tier fails.
    func fetch(url: URL) async throws -> WebContent
}

/// Errors surfaced by a ``WebContentFetcher``. Distinguishes user-actionable
/// cases (bad URL, consent needed) from transport failures so the tool and UI
/// can respond appropriately.
public enum WebFetchError: Error, Sendable, Equatable {
    /// The string was not a fetchable http(s) URL.
    case invalidURL(String)
    /// The transport failed (DNS, TLS, timeout, non-2xx). Carries a message.
    case transport(String)
    /// Every eligible tier produced empty/unusable content.
    case noReadableContent
    /// Tier 3 (Jina) was the only remaining option but the domain has not been
    /// granted consent. The App layer should prompt, then retry.
    case jinaConsentRequired(domain: String)
}
