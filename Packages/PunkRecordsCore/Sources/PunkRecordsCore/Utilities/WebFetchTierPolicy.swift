import Foundation

/// Pure tier-selection policy for the web-fetch ladder. Given the outcome of a
/// cheaper tier, decides whether to escalate. Kept in Core so the escalation
/// thresholds are one tested source of truth, independent of the SwiftSoup /
/// WebKit / Jina implementations in Infra.
public enum WebFetchTierPolicy {

    /// Below this many characters of extracted body text, Tier 1's output is
    /// treated as "too sparse" and Tier 2 (headless browser) is tried. Matches
    /// the issue's ~250-char threshold — enough to distinguish a real article
    /// stub from a JS-shell page that rendered almost nothing server-side.
    public static let minReadableContentLength = 250

    /// Whether to escalate from Tier 1 (Readability) to Tier 2 (headless
    /// browser). Escalate when the extracted content is shorter than
    /// ``minReadableContentLength`` *or* an `isProbablyReaderable`-style check
    /// says the raw document is unlikely to be an article (both signal a page
    /// whose content only materializes after client-side JS runs).
    /// - Parameters:
    ///   - tier1CharacterCount: length of Tier 1's extracted body text.
    ///   - isProbablyReaderable: result of a readerable heuristic on the raw
    ///     HTML; pass `true` when unknown so a decent Tier 1 result is trusted.
    public static func shouldEscalateToBrowser(
        tier1CharacterCount: Int,
        isProbablyReaderable: Bool
    ) -> Bool {
        tier1CharacterCount < minReadableContentLength || !isProbablyReaderable
    }

    /// Whether Tier 2's output is itself too sparse to keep, making Tier 3
    /// (Jina, opt-in) the last resort. Same length threshold as Tier 1.
    public static func shouldConsiderJina(tier2CharacterCount: Int) -> Bool {
        tier2CharacterCount < minReadableContentLength
    }
}
