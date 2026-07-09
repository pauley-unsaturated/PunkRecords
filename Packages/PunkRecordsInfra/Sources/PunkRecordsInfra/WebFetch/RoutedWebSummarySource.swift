import Foundation
import NaturalLanguage
import PunkRecordsCore

/// What the URL-summarize flow needs from a routed fetch: the content to
/// summarize plus the routing verdict's consequences — which prompt variant to
/// use, an optional language directive, and (for PDF/video) the citation
/// resolver that replaces the default on-page text-fragment links.
public struct RoutedWebSummaryContent: Sendable {
    public let content: WebContent
    public let promptVariant: WebSummaryPrompt.Variant
    public let languageHint: LanguageHint?
    public let citationLinkResolver: WebSummaryPostProcessor.CitationLinkResolver?
    /// Non-nil when the extracted body exceeded the long-form threshold. The
    /// plan is currently INFORMATIONAL: single-pass summarization proceeds on
    /// the (prompt-truncated) body, and multi-call per-chunk → meta-summary
    /// orchestration is a tracked follow-up. Carried so callers can annotate
    /// the note and so the orchestration seam already has its input.
    public let chunkPlan: ChunkPlan?
}

/// A blocked route: the page was classified as paywalled or login-walled, so
/// there is nothing sensible to summarize. `userFacingMessage` is shown as-is.
public struct RoutedWebSummaryBlockedError: Error, LocalizedError, Sendable {
    public let reason: BlockReason
    public var errorDescription: String? { reason.userFacingMessage }
}

/// Routes a URL through ``URLIngestClassifier`` and the matching content
/// source (PUNK-zup), so the summarize flow degrades deterministically instead
/// of summarizing garbage:
///
/// - PDF (suffix or Content-Type) → ``PDFIngestExtracting`` (PDFKit), page-
///   numbered markdown, `#page=N` citations.
/// - YouTube/Vimeo → ``VideoTranscriptProviding``, transcript markdown,
///   `&t=Ns` citations.
/// - Login-ish URL patterns → ``RoutedWebSummaryBlockedError`` before any
///   fetch; "HTTP 401/403" ladder failures map to the same error.
/// - Everything else → the regular three-tier article ladder, then
///   post-extraction classification: paywall (short body + marker/domain,
///   re-inspecting the page HTML only in that suspicious case),
///   transcript-shaped body → transcript prompt variant, long form → chunk
///   plan, `<html lang>`/on-device language recognition → language hint.
///
/// Known scope limits (deliberate, tracked in beads): redirect chains are not
/// observable through the current ladder, so login walls that 200-redirect to
/// an SSO host are only caught by URL-pattern/paywall heuristics; long-form
/// chunk plans do not yet drive multi-call summarization.
public struct RoutedWebSummarySource: Sendable {
    private let httpClient: any WebHTTPClient
    private let pdfExtractor: any PDFIngestExtracting
    private let transcriptProvider: any VideoTranscriptProviding
    private let articleFetcher: any WebContentFetcher
    private let now: @Sendable () -> Date

    public init(
        httpClient: any WebHTTPClient = URLSessionWebHTTPClient(),
        pdfExtractor: any PDFIngestExtracting = PDFKitTextExtractor(),
        transcriptProvider: any VideoTranscriptProviding = YouTubeTranscriptProvider(),
        articleFetcher: any WebContentFetcher,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.pdfExtractor = pdfExtractor
        self.transcriptProvider = transcriptProvider
        self.articleFetcher = articleFetcher
        self.now = now
    }

    /// The default router over the same three-tier ladder the chat `web_fetch`
    /// tool uses. `@MainActor` because the ladder's browser-tier extractor is
    /// WKWebView-backed and must be constructed on the main actor.
    @MainActor
    public static func makeDefault(
        vaultRoot: URL?,
        jinaConsent: @escaping @Sendable (URL) async -> Bool
    ) -> RoutedWebSummarySource {
        RoutedWebSummarySource(
            articleFetcher: ThreeTierWebContentFetcher.makeDefault(
                vaultRoot: vaultRoot,
                jinaConsent: jinaConsent
            )
        )
    }

    public func fetch(url: URL) async throws -> RoutedWebSummaryContent {
        // URL-only routing — no network needed to decide these.
        let urlSignals = URLIngestSignals(requestedURL: url)
        if PDFDetector.isPDF(contentType: nil, url: url) {
            return try await pdfContent(url: url)
        }
        if let target = VideoDetector.detect(signals: urlSignals) {
            return try await videoContent(target: target)
        }
        if let reason = LoginWallDetector.detect(signals: urlSignals) {
            throw RoutedWebSummaryBlockedError(reason: reason)
        }

        // Article path: the regular ladder. Map auth-flavored transport
        // failures to the login-wall outcome instead of a generic error.
        let content: WebContent
        do {
            content = try await articleFetcher.fetch(url: url)
        } catch let error as WebFetchError {
            if case .transport(let message) = error,
               message.contains("HTTP 401") || message.contains("HTTP 403"),
               let reason = LoginWallDetector.detect(
                   signals: URLIngestSignals(requestedURL: url, httpStatus: statusCode(in: message))
               ) {
                throw RoutedWebSummaryBlockedError(reason: reason)
            }
            throw error
        }

        // A served-as-PDF URL without the .pdf suffix: the ladder can't extract
        // it — but tier 1 usually reports no readable content first, so the
        // common case is handled by the suffix check above. Content-Type-based
        // PDF detection without a second request is a documented gap.

        // Post-extraction classification. The paywall check needs the page's
        // class/id blob, which the ladder doesn't expose — re-inspect the HTML
        // only when the body is suspiciously short (the detector's own trigger),
        // so the happy path stays single-fetch.
        let body = content.contentMarkdown
        var signals = URLIngestSignals(
            requestedURL: url,
            finalURL: content.canonicalURL ?? content.sourceURL,
            languageRecognizerHint: recognizedLanguage(of: body)
        )
        if body.count < PaywallDetector.bodyLengthThreshold,
           let response = try? await httpClient.get(url, headers: [:], timeout: 15) {
            let extracted = URLIngestSignalExtractor.extract(html: response.text())
            signals.ogType = extracted.ogType
            signals.htmlLangAttribute = extracted.htmlLang
            signals.bodyClassIdentityBlob = extracted.bodyClassIdentityBlob
        }

        let decision = URLIngestClassifier.classify(signals: signals, bodyText: body)
        switch decision.route {
        case .paywalled(let reason), .loginWalled(let reason):
            throw RoutedWebSummaryBlockedError(reason: reason)
        case .video(let target):
            // og:type video on a host the URL check missed.
            return try await videoContent(target: target)
        case .pdf:
            return try await pdfContent(url: url)
        case .conversationTranscript:
            return RoutedWebSummaryContent(
                content: content,
                promptVariant: .transcript,
                languageHint: decision.languageHint,
                citationLinkResolver: nil,
                chunkPlan: nil
            )
        case .longForm(let plan):
            return RoutedWebSummaryContent(
                content: content,
                promptVariant: .standard,
                languageHint: decision.languageHint,
                citationLinkResolver: nil,
                chunkPlan: plan
            )
        case .article:
            return RoutedWebSummaryContent(
                content: content,
                promptVariant: .standard,
                languageHint: decision.languageHint,
                citationLinkResolver: nil,
                chunkPlan: nil
            )
        }
    }

    // MARK: - Routes

    private func pdfContent(url: URL) async throws -> RoutedWebSummaryContent {
        let response = try await httpClient.get(url, headers: [:], timeout: 30)
        let extraction = try pdfExtractor.extract(data: response.body, sourceURL: response.finalURL)
        return RoutedWebSummaryContent(
            content: PDFSummaryRenderer.makeContent(from: extraction, sourceURL: response.finalURL, extractedAt: now()),
            promptVariant: .standard,
            languageHint: nil,
            citationLinkResolver: PDFSummaryRenderer.citationLinkResolver(pages: extraction.pages, pdfURL: response.finalURL),
            chunkPlan: nil
        )
    }

    private func videoContent(target: VideoTarget) async throws -> RoutedWebSummaryContent {
        let transcript = try await transcriptProvider.fetchTranscript(for: target)
        return RoutedWebSummaryContent(
            content: VideoSummaryRenderer.makeContent(from: transcript, sourceURL: target.sourceURL, extractedAt: now()),
            promptVariant: .transcript,
            languageHint: nil,
            citationLinkResolver: VideoSummaryRenderer.citationLinkResolver(transcript: transcript, videoURL: target.sourceURL),
            chunkPlan: nil
        )
    }

    // MARK: - Helpers

    /// On-device best-guess language of `text` (BCP-47 primary code), for
    /// ``ForeignLanguageDetector`` when the `<html lang>` attribute is absent.
    private func recognizedLanguage(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }

    private func statusCode(in transportMessage: String) -> Int? {
        if transportMessage.contains("HTTP 401") { return 401 }
        if transportMessage.contains("HTTP 403") { return 403 }
        return nil
    }
}
