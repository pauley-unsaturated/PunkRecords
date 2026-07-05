import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("ThreeTierWebContentFetcher — tier orchestration + consent gating")
struct ThreeTierWebContentFetcherTests {

    // MARK: - Test doubles

    /// Records every URL requested and serves canned bodies keyed by URL.
    final class SpyHTTPClient: WebHTTPClient, @unchecked Sendable {
        var bodies: [String: String] = [:]
        var finalURLs: [String: URL] = [:]
        private let lock = NSLock()
        private var _requested: [URL] = []

        var requestedURLs: [URL] { lock.withLock { _requested } }

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> WebHTTPResponse {
            lock.withLock { _requested.append(url) }
            let body = bodies[url.absoluteString] ?? ""
            return WebHTTPResponse(
                body: Data(body.utf8),
                finalURL: finalURLs[url.absoluteString] ?? url,
                mimeType: "text/html",
                textEncodingName: "utf-8"
            )
        }
    }

    struct StubBrowser: BrowserContentExtracting {
        let result: ReadabilityResult?
        func extract(url: URL) async throws -> ReadabilityResult {
            guard let result else { throw WebFetchError.noReadableContent }
            return result
        }
    }

    // MARK: - Fixtures

    private let pageURL = URL(string: "https://example.com/post")!

    private static let richArticle = """
    <html><head><title>Rich Article</title></head><body>
    <article class="content">
      <h1>Rich Article</h1>
      <p>This is a comfortably long opening paragraph, with commas, clauses, and enough prose
         that Tier 1 extraction stays on Tier 1 without escalating to the browser at all.</p>
      <p>A second paragraph, similarly long, with more commas and words, cements the article as
         real content well above the extraction threshold used by the policy.</p>
    </article></body></html>
    """

    private static let sparsePage = """
    <html><head><title>App</title></head><body><div id="root"></div><script>go()</script></body></html>
    """

    private func fixedNow() -> @Sendable () -> Date { { Date(timeIntervalSince1970: 1_000) } }

    // MARK: - Tier 1

    @Test("Rich page resolves on Tier 1 without touching Tier 2/3")
    func tier1Only() async throws {
        let http = SpyHTTPClient()
        http.bodies[pageURL.absoluteString] = Self.richArticle
        let fetcher = ThreeTierWebContentFetcher(httpClient: http, now: fixedNow())

        let content = try await fetcher.fetch(url: pageURL)
        #expect(content.tier == .readability)
        #expect(content.title == "Rich Article")
        #expect(content.headings.first?.anchorID == "rich-article")
        #expect(content.extractedAt == Date(timeIntervalSince1970: 1_000))
        #expect(http.requestedURLs == [pageURL])
    }

    // MARK: - Tier 2

    @Test("Sparse page escalates to the headless browser tier")
    func escalatesToTier2() async throws {
        let http = SpyHTTPClient()
        http.bodies[pageURL.absoluteString] = Self.sparsePage
        let browserHTML = "<h1>Rendered</h1>" + String(repeating: "<p>Rendered content paragraph.</p>", count: 20)
        let browser = StubBrowser(result: ReadabilityResult(
            title: "Rendered", byline: nil, contentHTML: browserHTML,
            textContent: String(repeating: "x", count: 600)
        ))
        let fetcher = ThreeTierWebContentFetcher(httpClient: http, browserExtractor: browser, now: fixedNow())

        let content = try await fetcher.fetch(url: pageURL)
        #expect(content.tier == .headlessBrowser)
        #expect(content.title == "Rendered")
        #expect(content.contentMarkdown.contains("Rendered content paragraph."))
        // Only the original page was fetched over HTTP — no Jina request.
        #expect(http.requestedURLs == [pageURL])
    }

    // MARK: - Tier 3 consent gating (the load-bearing privacy test)

    @Test("Without consent, Jina is never requested and a consent error surfaces")
    func consentGatingBlocksJinaRequest() async throws {
        let http = SpyHTTPClient()
        http.bodies[pageURL.absoluteString] = Self.sparsePage // Tier 1 yields nothing
        // No browser extractor and no Jina consent → Tier 3 must be blocked.
        let fetcher = ThreeTierWebContentFetcher(
            httpClient: http,
            jinaEnabled: true,
            jinaConsent: { _ in false },
            now: fixedNow()
        )

        await #expect(throws: WebFetchError.jinaConsentRequired(domain: "example.com")) {
            _ = try await fetcher.fetch(url: pageURL)
        }
        // Critical: no request went to r.jina.ai.
        #expect(http.requestedURLs.allSatisfy { $0.host != "r.jina.ai" })
        #expect(http.requestedURLs == [pageURL])
    }

    @Test("With consent, Jina is used and its markdown is returned")
    func consentGrantedUsesJina() async throws {
        let http = SpyHTTPClient()
        http.bodies[pageURL.absoluteString] = Self.sparsePage
        let jinaEndpoint = JinaReader.endpoint(for: pageURL)
        http.bodies[jinaEndpoint.absoluteString] = """
        Title: Jina Title
        URL Source: https://example.com/post
        Markdown Content:
        # Jina Title

        A cleaned paragraph rendered by the remote reader service, long enough to be real content.
        """
        let fetcher = ThreeTierWebContentFetcher(
            httpClient: http,
            jinaEnabled: true,
            jinaConsent: { _ in true },
            now: fixedNow()
        )

        let content = try await fetcher.fetch(url: pageURL)
        #expect(content.tier == .jinaReader)
        #expect(content.title == "Jina Title")
        #expect(content.contentMarkdown.contains("cleaned paragraph"))
        #expect(http.requestedURLs.contains(jinaEndpoint))
    }

    @Test("Consent withheld but some Tier 1 content exists → return it, no Jina call, no throw")
    func gracefulWhenSomeContent() async throws {
        let http = SpyHTTPClient()
        // Short-but-nonempty article: below the 250-char threshold, so it wants to
        // escalate, but there IS content to fall back on.
        http.bodies[pageURL.absoluteString] = """
        <html><body><article class="content"><h1>Note</h1>
        <p>A short but real paragraph of content here.</p></article></body></html>
        """
        let fetcher = ThreeTierWebContentFetcher(
            httpClient: http, jinaEnabled: true, jinaConsent: { _ in false }, now: fixedNow()
        )

        let content = try await fetcher.fetch(url: pageURL)
        #expect(content.tier == .readability)
        #expect(content.contentMarkdown.contains("short but real paragraph"))
        #expect(http.requestedURLs == [pageURL])
    }

    // MARK: - Caching

    @Test("Fetched HTML is cached under the vault's Web/_cache tree")
    func cachesHTML() async throws {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("punk-web-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let http = SpyHTTPClient()
        http.bodies[pageURL.absoluteString] = Self.richArticle
        let fetcher = ThreeTierWebContentFetcher(httpClient: http, vaultRoot: vaultRoot, now: fixedNow())
        _ = try await fetcher.fetch(url: pageURL)

        let expected = vaultRoot.appendingPathComponent(VaultPaths.webCachePath(forURL: pageURL))
        #expect(FileManager.default.fileExists(atPath: expected.path))
        let cached = try String(contentsOf: expected, encoding: .utf8)
        #expect(cached.contains("Rich Article"))
    }

    // MARK: - Canonical URL

    @Test("A redirect's final URL becomes the canonical URL")
    func canonicalFromRedirect() async throws {
        let http = SpyHTTPClient()
        let finalURL = URL(string: "https://example.com/post-canonical")!
        http.bodies[pageURL.absoluteString] = Self.richArticle
        http.finalURLs[pageURL.absoluteString] = finalURL
        let fetcher = ThreeTierWebContentFetcher(httpClient: http, now: fixedNow())

        let content = try await fetcher.fetch(url: pageURL)
        #expect(content.sourceURL == pageURL)
        #expect(content.canonicalURL == finalURL)
    }
}
