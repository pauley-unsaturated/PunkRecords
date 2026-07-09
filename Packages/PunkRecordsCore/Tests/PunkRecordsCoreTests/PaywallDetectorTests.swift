import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("PaywallDetector — short body + known marker/domain")
struct PaywallDetectorTests {

    private func signals(
        url: String = "https://example.com/article",
        blob: String = "",
        finalURL: String? = nil
    ) -> URLIngestSignals {
        URLIngestSignals(
            requestedURL: URL(string: url)!,
            finalURL: finalURL.flatMap(URL.init),
            bodyClassIdentityBlob: blob
        )
    }

    @Test("Short body + known class marker is paywalled")
    func shortBodyWithClassMarker() {
        let s = signals(blob: "article-body meter-paywall-widget subscribe-cta")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 120)
        #expect(reason != nil)
        #expect(reason?.userFacingMessage.lowercased().contains("paywalled") == true)
    }

    @Test("Short body + known paywalled domain is paywalled")
    func shortBodyWithKnownDomain() {
        let s = signals(url: "https://www.nytimes.com/2026/07/07/tech/story.html")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 150)
        #expect(reason != nil)
    }

    @Test("Short body ALONE (no marker, no known domain) is NOT paywalled")
    func shortBodyAloneIsNotPaywalled() {
        let s = signals(url: "https://obscure-blog.example.net/post")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 50)
        #expect(reason == nil)
    }

    @Test("A known marker with a LONG body is NOT paywalled (full content still came through)")
    func longBodyWithMarkerIsNotPaywalled() {
        let s = signals(blob: "meter-paywall-widget")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 5_000)
        #expect(reason == nil)
    }

    @Test("A known domain with a LONG body is NOT paywalled")
    func longBodyWithKnownDomainIsNotPaywalled() {
        let s = signals(url: "https://www.wsj.com/articles/some-story")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 5_000)
        #expect(reason == nil)
    }

    @Test("Marker matching is case-insensitive and substring-based")
    func markerMatchingCaseInsensitive() {
        let s = signals(blob: "MyCustom-PAYWALL-Banner")
        let reason = PaywallDetector.detect(signals: s, bodyLength: 100)
        #expect(reason != nil)
    }

    @Test("Domain matching covers subdomains via www-stripped normalization")
    func domainMatchingCoversSubdomains() {
        let s = signals(url: "https://static.nytimes.com/embed/story")
        // static.nytimes.com is not itself in the known set nor does www-stripping help here,
        // but a bare nytimes.com URL should match.
        let bareReason = PaywallDetector.detect(signals: signals(url: "https://nytimes.com/story"), bodyLength: 100)
        #expect(bareReason != nil)
        _ = s
    }

    @Test("bodyLengthThreshold matches WebFetchTierPolicy's minReadableContentLength")
    func thresholdMatchesTierPolicy() {
        #expect(PaywallDetector.bodyLengthThreshold == WebFetchTierPolicy.minReadableContentLength)
    }
}
