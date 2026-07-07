import Foundation

/// Builds W3C [scroll-to-text-fragment](https://wicg.github.io/scroll-to-text-fragment/)
/// directives (`#:~:text=...`) that deep-link a citation's supporting text back
/// to its exact spot on the source page.
///
/// Pure and deterministic: given the same `supportingText` and `pageText`, the
/// output never changes. Matching policy, documented here because it's a
/// deliberate simplification rather than a full re-implementation of the
/// browser's fuzzy text-fragment matcher:
///  - Case-sensitive exact match.
///  - Runs of whitespace (including newlines) in `supportingText` match any run
///    of whitespace in `pageText`, so a quote that wrapped across a markdown
///    line break still matches.
///  - When a match isn't unique, the builder grows a word-based prefix/suffix
///    window (see ``minContextWords``/``maxContextWords``) around the FIRST
///    occurrence until `prefix-,text,-suffix` pins a unique span, per the
///    spec's disambiguation syntax. If it can't within the window, it gives up
///    (``Outcome/ambiguous``) rather than guessing which occurrence was meant.
public enum TextFragmentBuilder {
    /// The result of resolving `supportingText` against a page's plain text.
    public enum Outcome: Sendable, Equatable {
        /// `supportingText` occurred exactly once. `fragment` is the
        /// `text=...` directive body (no leading `#:~:`).
        case unique(fragment: String)
        /// `supportingText` occurred more than once, but prefix/suffix context
        /// around the first occurrence pinned it to a unique span. `fragment`
        /// is the full `text=prefix-,text,-suffix` directive body.
        case disambiguated(fragment: String)
        /// `supportingText` does not occur in `pageText` at all.
        case notFound
        /// `supportingText` occurs more than once, and even the widest
        /// prefix/suffix window this builder tries doesn't disambiguate it.
        case ambiguous
    }

    /// Smallest prefix/suffix context (in words) tried when disambiguating.
    static let minContextWords = 3
    /// Largest prefix/suffix context (in words) tried before giving up.
    static let maxContextWords = 10

    // MARK: - Public API

    /// Resolve `supportingText` against `pageText` and describe the outcome.
    public static func build(supportingText: String, pageText: String) -> Outcome {
        let needle = supportingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .notFound }

        let occurrences = findOccurrences(of: needle, in: pageText)
        guard let first = occurrences.first else { return .notFound }
        guard occurrences.count > 1 else {
            return .unique(fragment: "text=" + percentEncode(needle))
        }

        for contextWords in stride(from: minContextWords, through: maxContextWords, by: 1) {
            let prefix = words(before: first.lowerBound, in: pageText, count: contextWords)
            let suffix = words(after: first.upperBound, in: pageText, count: contextWords)
            guard !prefix.isEmpty || !suffix.isEmpty else { continue }

            let combined = [prefix, needle, suffix].filter { !$0.isEmpty }.joined(separator: " ")
            if findOccurrences(of: combined, in: pageText).count == 1 {
                var fragment = "text="
                if !prefix.isEmpty { fragment += percentEncode(prefix) + "-," }
                fragment += percentEncode(needle)
                if !suffix.isEmpty { fragment += ",-" + percentEncode(suffix) }
                return .disambiguated(fragment: fragment)
            }
        }
        return .ambiguous
    }

    /// Convenience: resolve `supportingText` against `pageText` and, on
    /// success, return the full deep-link URL (`pageURL` with any existing
    /// fragment replaced by the text-fragment directive). `nil` when the
    /// citation couldn't be resolved (``Outcome/notFound``/``Outcome/ambiguous``).
    public static func url(pageURL: URL, supportingText: String, pageText: String) -> URL? {
        switch build(supportingText: supportingText, pageText: pageText) {
        case .unique(let fragment), .disambiguated(let fragment):
            return URL(string: baseURLString(pageURL) + "#:~:" + fragment)
        case .notFound, .ambiguous:
            return nil
        }
    }

    /// Percent-encode `text` for use inside a text-fragment directive: encodes
    /// everything a URL fragment normally requires, PLUS `-`, `,`, and `&`
    /// (which the text-fragment spec reserves as directive syntax — prefix/
    /// suffix separators and the multi-directive separator, respectively).
    public static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? text
    }

    // MARK: - Private

    private static let allowedCharacters: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.remove(charactersIn: "-,&")
        return set
    }()

    private static func baseURLString(_ url: URL) -> String {
        let s = url.absoluteString
        guard let hashIndex = s.firstIndex(of: "#") else { return s }
        return String(s[..<hashIndex])
    }

    /// Find every occurrence of `needle` in `haystack`, treating any run of
    /// whitespace in `needle` as matching any run of whitespace in `haystack`.
    /// Case-sensitive.
    ///
    /// Deliberately OVERLAPPING (unlike `NSRegularExpression.matches(in:range:)`'s
    /// default non-overlapping scan): the disambiguation loop in ``build(supportingText:pageText:)``
    /// searches for a `prefix + needle + suffix` window, and when two real
    /// occurrences of `needle` sit close enough together that their windows
    /// would span into the same intervening text, a non-overlapping scan can
    /// "consume" one match while searching for the other and undercount to 1
    /// — silently reporting a still-ambiguous location as disambiguated. An
    /// overlapping scan (advance one code unit past each match's START, not
    /// its end) always finds every valid occurrence.
    static func findOccurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNeedle.isEmpty, !haystack.isEmpty else { return [] }

        let escaped = NSRegularExpression.escapedPattern(for: trimmedNeedle)
        let pattern = escaped.replacingOccurrences(
            of: "[ \\t\\n\\r]+",
            with: "\\\\s+",
            options: .regularExpression
        )
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsHaystack = haystack as NSString
        let length = nsHaystack.length
        var results: [Range<String.Index>] = []
        var searchLocation = 0
        while searchLocation <= length {
            let searchRange = NSRange(location: searchLocation, length: length - searchLocation)
            guard let match = regex.firstMatch(in: haystack, options: [], range: searchRange) else { break }
            if let range = Range(match.range, in: haystack) {
                results.append(range)
            }
            searchLocation = match.range.location + 1
        }
        return results
    }

    /// The last `count` whitespace-delimited words immediately before `index`,
    /// re-joined with single spaces (empty when `index` is document-start).
    private static func words(before index: String.Index, in text: String, count: Int) -> String {
        let slice = text[text.startIndex..<index]
        let tokens = slice.split(whereSeparator: { $0.isWhitespace })
        return tokens.suffix(count).joined(separator: " ")
    }

    /// The first `count` whitespace-delimited words immediately after `index`,
    /// re-joined with single spaces (empty when `index` is document-end).
    private static func words(after index: String.Index, in text: String, count: Int) -> String {
        let slice = text[index...]
        let tokens = slice.split(whereSeparator: { $0.isWhitespace })
        return tokens.prefix(count).joined(separator: " ")
    }
}
