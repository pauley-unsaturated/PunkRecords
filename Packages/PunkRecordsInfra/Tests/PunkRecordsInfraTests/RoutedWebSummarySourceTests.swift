import Foundation
import Testing
import PunkRecordsCore
@testable import PunkRecordsInfra

/// Glue tests for ``RoutedWebSummarySource`` (PUNK-zup): each ingest route
/// reaches the right content source and carries the right prompt variant /
/// citation resolver, with every collaborator mocked — no network, no PDFKit.
@Suite("RoutedWebSummarySource — route glue over mocked sources")
struct RoutedWebSummarySourceTests {
    // MARK: - Mocks

    private final class MockHTTPClient: WebHTTPClient, @unchecked Sendable {
        var responseBody = Data()
        var responseHTML: String?
        private(set) var requestedURLs: [URL] = []

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> WebHTTPResponse {
            requestedURLs.append(url)
            let body = responseHTML.map { Data($0.utf8) } ?? responseBody
            return WebHTTPResponse(body: body, finalURL: url, mimeType: nil, textEncodingName: nil)
        }
    }

    private struct MockPDFExtractor: PDFIngestExtracting {
        let result: PDFExtractionResult
        func extract(data: Data, sourceURL: URL) throws -> PDFExtractionResult { result }
    }

    private struct MockTranscriptProvider: VideoTranscriptProviding {
        let transcript: VideoTranscript
        func fetchTranscript(for target: VideoTarget) async throws -> VideoTranscript { transcript }
    }

    private final class MockArticleFetcher: WebContentFetcher, @unchecked Sendable {
        var content: WebContent?
        var error: WebFetchError?
        private(set) var fetchedURLs: [URL] = []

        func fetch(url: URL) async throws -> WebContent {
            fetchedURLs.append(url)
            if let error { throw error }
            guard let content else { throw WebFetchError.noReadableContent }
            return content
        }
    }

    private func makeSource(
        httpClient: MockHTTPClient = MockHTTPClient(),
        pdfPages: [PDFPageText] = [PDFPageText(pageNumber: 1, text: "PDF page text")],
        articleFetcher: MockArticleFetcher = MockArticleFetcher()
    ) -> (RoutedWebSummarySource, MockHTTPClient, MockArticleFetcher) {
        let target = VideoTarget(
            provider: .youTube,
            videoID: "abc123",
            sourceURL: URL(string: "https://www.youtube.com/watch?v=abc123")!
        )
        let source = RoutedWebSummarySource(
            httpClient: httpClient,
            pdfExtractor: MockPDFExtractor(result: PDFExtractionResult(title: "Paper", pages: pdfPages)),
            transcriptProvider: MockTranscriptProvider(transcript: VideoTranscript(
                target: target,
                title: "A Talk",
                languageCode: "en",
                cues: [TranscriptCue(startSeconds: 12, text: "hello world")]
            )),
            articleFetcher: articleFetcher,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        return (source, httpClient, articleFetcher)
    }

    private func articleContent(body: String, url: URL) -> WebContent {
        WebContent(
            title: "Article",
            byline: nil,
            contentMarkdown: body,
            headings: [],
            extractedAt: Date(timeIntervalSince1970: 1_750_000_000),
            tier: .readability,
            sourceURL: url,
            canonicalURL: nil
        )
    }

    // MARK: - URL-only routes

    @Test("A .pdf URL routes to the PDF extractor and never hits the article ladder")
    func pdfBySuffix() async throws {
        let (source, http, articles) = makeSource()
        http.responseBody = Data("%PDF-1.7 fake".utf8)

        let routed = try await source.fetch(url: URL(string: "https://example.com/paper.pdf")!)

        #expect(routed.content.tier == .pdf)
        #expect(routed.promptVariant == .standard)
        #expect(routed.citationLinkResolver != nil)
        #expect(articles.fetchedURLs.isEmpty)
    }

    @Test("A YouTube watch URL routes to the transcript provider with the transcript variant")
    func videoByHost() async throws {
        let (source, _, articles) = makeSource()

        let routed = try await source.fetch(url: URL(string: "https://www.youtube.com/watch?v=abc123")!)

        #expect(routed.content.tier == .videoTranscript)
        #expect(routed.promptVariant == .transcript)
        #expect(routed.citationLinkResolver != nil)
        #expect(articles.fetchedURLs.isEmpty)
    }

    @Test("A login-ish URL is blocked before any fetch")
    func loginURLBlockedUpFront() async {
        let (source, http, articles) = makeSource()

        await #expect(throws: RoutedWebSummaryBlockedError.self) {
            _ = try await source.fetch(url: URL(string: "https://example.com/login?next=/article")!)
        }
        #expect(http.requestedURLs.isEmpty)
        #expect(articles.fetchedURLs.isEmpty)
    }

    // MARK: - Post-extraction routes

    @Test("A short body with a paywall class marker is blocked with the paywall message")
    func paywallBlocked() async {
        let url = URL(string: "https://example.com/story")!
        let (source, http, articles) = makeSource()
        articles.content = articleContent(body: "Subscribe to continue.", url: url)
        http.responseHTML = #"<html><body><div class="paywall-overlay">Subscribe</div></body></html>"#

        await #expect(throws: RoutedWebSummaryBlockedError.self) {
            _ = try await source.fetch(url: url)
        }
    }

    @Test("An HTTP 403 ladder failure maps to the login-wall outcome")
    func forbiddenMapsToLoginWall() async {
        let url = URL(string: "https://example.com/members-only")!
        let (source, _, articles) = makeSource()
        articles.error = .transport("HTTP 403 for \(url.absoluteString)")

        await #expect(throws: RoutedWebSummaryBlockedError.self) {
            _ = try await source.fetch(url: url)
        }
    }

    @Test("A transcript-shaped body selects the transcript prompt variant")
    func transcriptBody() async throws {
        let url = URL(string: "https://example.com/interview")!
        let lines = (0..<40).map { "Speaker\($0 % 3): line \($0) of the conversation with plenty of words in it." }
        let (source, _, articles) = makeSource()
        articles.content = articleContent(body: lines.joined(separator: "\n"), url: url)

        let routed = try await source.fetch(url: url)

        #expect(routed.promptVariant == .transcript)
        #expect(routed.citationLinkResolver == nil)
    }

    @Test("A long-form body carries a chunk plan; a plain article does not")
    func longFormCarriesPlan() async throws {
        let url = URL(string: "https://example.com/book")!
        let paragraph = String(repeating: "sentence with several words in it. ", count: 200)
        let longBody = (0..<40).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let (source, _, articles) = makeSource()
        articles.content = articleContent(body: longBody, url: url)

        let routed = try await source.fetch(url: url)
        #expect(routed.chunkPlan != nil)
        #expect(routed.promptVariant == .standard)

        let (plainSource, _, plainArticles) = makeSource()
        plainArticles.content = articleContent(
            body: "A perfectly ordinary readable article body with enough length to not look paywalled. "
                + String(repeating: "More ordinary prose. ", count: 30),
            url: url
        )
        let plain = try await plainSource.fetch(url: url)
        #expect(plain.chunkPlan == nil)
        #expect(plain.promptVariant == .standard)
        #expect(plain.citationLinkResolver == nil)
    }
}
