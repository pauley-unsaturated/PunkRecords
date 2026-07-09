import Foundation

/// Routes a fetched (or about-to-be-fetched) URL to the right handling
/// strategy, per PUNK-zup: "URL ingest failure-mode handling." Pure and
/// deterministic — every input maps to exactly one ``IngestRoute``, so the
/// summarize flow always has a defined, testable outcome instead of
/// falling through to "summarize whatever garbage we extracted."
///
/// ## Precedence
///
/// `classify` evaluates detectors in this fixed order and returns the first
/// match; only ``IngestRoute/article`` falls through everything:
///
/// 1. ``PDFDetector`` — content-type/URL-suffix is decisive and orthogonal to
///    every other signal; nothing else about the response matters once we
///    know it's a PDF.
/// 2. ``VideoDetector`` — host/`og:type` is likewise decisive: a YouTube/Vimeo
///    URL is never also "the article body," so there's no page-content
///    heuristic that could out-rank it.
/// 3. ``LoginWallDetector`` — an HTTP 401/403 or a login-redirect is a hard
///    transport-layer signal. Checked before the paywall heuristic because
///    it's unambiguous where the paywall heuristic is probabilistic (short
///    body + a marker), and because a login-walled response often has NO
///    body to run the paywall heuristic against usefully.
/// 4. ``PaywallDetector`` — a content-layer block signal (short body + a
///    known marker/domain). Deliberately requires BOTH conditions: a short
///    body alone is NOT paywall evidence, it's just "extraction came back
///    thin" (which the existing 3-tier fetch ladder already tried to fix,
///    and which — per PUNK-zup's SPA fixture requirement — must NOT be
///    misreported as a paywall).
/// 5. ``TranscriptHeuristic`` — checked before long-form length, because
///    transcript-ness changes WHICH PROMPT TEMPLATE applies
///    (``WebSummaryPrompt/Variant/transcript``), which matters more to output
///    quality than length does. A transcript that's ALSO long-form only gets
///    the transcript prompt today — chunking a long transcript with the
///    transcript-variant prompt per chunk is a natural follow-up, not
///    implemented here (`IngestRoute` has no case for "both," by design; see
///    the type's doc comment on why language composes but these two don't).
/// 6. ``LongFormChunkPlanner`` — a hard context-budget constraint.
/// 7. Fallback: ``IngestRoute/article``.
///
/// ``LanguageHint`` (from ``ForeignLanguageDetector``) is orthogonal to all of
/// the above and is always computed and attached to the returned
/// ``IngestDecision``, regardless of which route fired.
public enum URLIngestClassifier {
    /// Classify a fetched URL.
    /// - Parameters:
    ///   - signals: transport/metadata signals (see ``URLIngestSignals``).
    ///   - bodyText: the extracted article body (empty string when the route
    ///     is decided before any body extraction happens, e.g. video/PDF
    ///     detected from the URL/content-type alone).
    public static func classify(signals: URLIngestSignals, bodyText: String) -> IngestDecision {
        let route = classifyRoute(signals: signals, bodyText: bodyText)
        let languageHint = ForeignLanguageDetector.detect(signals: signals)
        return IngestDecision(route: route, languageHint: languageHint)
    }

    private static func classifyRoute(signals: URLIngestSignals, bodyText: String) -> IngestRoute {
        if PDFDetector.isPDF(contentType: signals.contentType, url: signals.finalURL) {
            return .pdf
        }
        if let target = VideoDetector.detect(signals: signals) {
            return .video(target)
        }
        if let reason = LoginWallDetector.detect(signals: signals) {
            return .loginWalled(reason)
        }
        if let reason = PaywallDetector.detect(signals: signals, bodyLength: bodyText.count) {
            return .paywalled(reason)
        }
        if TranscriptHeuristic.looksLikeTranscript(bodyText) {
            return .conversationTranscript
        }
        if LongFormChunkPlanner.isLongForm(bodyText: bodyText) {
            return .longForm(LongFormChunkPlanner.plan(bodyText: bodyText))
        }
        return .article
    }
}
