import Foundation

/// Detects a paywalled page, per PUNK-zup's failure mode #3. Pure string/set
/// matching — no HTML parsing (Infra extracts ``URLIngestSignals/bodyClassIdentityBlob``
/// from the DOM; this only substring-searches the already-flattened blob).
public enum PaywallDetector {
    /// Below this many characters of extracted body text, combined with a
    /// known-marker signal, a page is treated as paywalled. Reuses
    /// ``WebFetchTierPolicy/minReadableContentLength`` — by the time this
    /// runs, the fetch ladder has already been exhausted, so a still-short
    /// body plus a signal means "blocked", not "needs a better tier."
    public static var bodyLengthThreshold: Int { WebFetchTierPolicy.minReadableContentLength }

    /// Known metered/paywalled publisher domains. A seed list, not
    /// exhaustive by design — extend as real-world misses turn up. Matched
    /// via ``WebFetchConsentPolicy/consentDomain(for:)`` normalization
    /// (lowercased, leading `www.` stripped), so subdomains still match.
    public static let knownDomains: Set<String> = [
        "nytimes.com", "wsj.com", "ft.com", "washingtonpost.com", "bloomberg.com",
        "economist.com", "newyorker.com", "theatlantic.com", "wired.com",
        "businessinsider.com", "theinformation.com", "medium.com", "forbes.com",
        "barrons.com", "hbr.org", "seekingalpha.com", "thetimes.co.uk",
    ]

    /// Substrings of a page's flattened class/id attributes that indicate a
    /// metered-paywall widget is present. Matched case-insensitively.
    public static let knownClassMarkers: [String] = [
        "paywall", "piano-inline", "meter-paywall", "subscriber-only",
        "subscription-required", "regwall", "gated-content", "premium-content",
    ]

    static let userFacingMessage =
        "This page appears to be paywalled — open it in your browser and re-trigger the summary from there."

    /// Whether `signals`/`bodyLength` indicate a paywalled page. Requires
    /// BOTH a short body AND a specific signal (a known class marker, or a
    /// known paywall domain) — a short body alone just means "no readable
    /// content" (``WebFetchError/noReadableContent``), not necessarily a
    /// paywall; see ``URLIngestClassifier``'s SPA fixture test for why that
    /// distinction matters.
    public static func detect(signals: URLIngestSignals, bodyLength: Int) -> BlockReason? {
        guard bodyLength < bodyLengthThreshold else { return nil }

        if hasKnownClassMarker(in: signals.bodyClassIdentityBlob) {
            return BlockReason(
                userFacingMessage: userFacingMessage,
                diagnostic: "matched paywall class/id marker on \(signals.finalURL.absoluteString)"
            )
        }
        if let domain = WebFetchConsentPolicy.consentDomain(for: signals.finalURL), knownDomains.contains(domain) {
            return BlockReason(userFacingMessage: userFacingMessage, diagnostic: "known paywalled domain: \(domain)")
        }
        return nil
    }

    static func hasKnownClassMarker(in blob: String) -> Bool {
        guard !blob.isEmpty else { return false }
        let lowered = blob.lowercased()
        return knownClassMarkers.contains { lowered.contains($0) }
    }
}
