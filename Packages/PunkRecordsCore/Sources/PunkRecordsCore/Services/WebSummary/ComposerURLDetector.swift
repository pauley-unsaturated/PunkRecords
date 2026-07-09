import Foundation

/// Detects a single summarizable URL in raw chat-composer text, backing the
/// "Summarize this URL" affordance (PUNK-ddq) and the clipboard-driven
/// "Summarize URL from Clipboard" command (which validates the pasteboard
/// string through the same rule).
///
/// **Affordance rule**: the ENTIRE trimmed text — after stripping any
/// backtick-fenced code spans, so a URL quoted in a code fence never counts —
/// must be exactly one `http(s)` URL and nothing else. A message that merely
/// *mentions* a URL among other words does NOT trigger: `"check this out
/// https://x.com, thoughts?"` returns `nil`, only a message that IS just the
/// link (typed or pasted into an empty/whitespace composer) returns one.
///
/// This is a deliberate choice over "contains a URL anywhere": chat messages
/// routinely cite links as part of an otherwise-ordinary question the user
/// wants answered in the conversation, and popping a "Summarize this URL"
/// affordance every time would be noisy and often wrong about intent. Pasting
/// (or typing) a bare URL with nothing else is the unambiguous "I want this
/// page, not a chat about it" signal, and it covers the paste case for free —
/// pasting a URL into an empty composer makes the composer's full text equal
/// to that URL, so no separate paste-event hook is needed; the caller just
/// re-evaluates this function whenever the composer text changes.
public enum ComposerURLDetector {

    /// Extract the summarizable URL from `text`, or `nil` if the affordance
    /// rule (see type doc) isn't satisfied.
    public static func summarizableURL(in text: String) -> URL? {
        let withoutFences = strippingCodeFences(from: text)
        let trimmed = withoutFences.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Replace the CONTENTS of triple-backtick and single-backtick spans with
    /// nothing, so a fenced URL never survives to be evaluated as "the entire
    /// message." Applied to whichever fence type is present; both may appear
    /// (a message consisting of only a fenced block strips to empty either way).
    static func strippingCodeFences(from text: String) -> String {
        var result = droppingDelimitedContent(in: text, delimiter: "```")
        result = droppingDelimitedContent(in: result, delimiter: "`")
        return result
    }

    /// Split `text` on `delimiter` and drop every odd-indexed segment (the
    /// content BETWEEN delimiter pairs), keeping the even-indexed segments
    /// (content outside any fence). An unterminated trailing fence still drops
    /// its (odd-indexed) tail content, which is the safe direction — better to
    /// under-detect a URL than treat fenced/quoted code as a live link.
    private static func droppingDelimitedContent(in text: String, delimiter: String) -> String {
        guard text.contains(delimiter) else { return text }
        let parts = text.components(separatedBy: delimiter)
        guard parts.count > 1 else { return text }
        return parts.enumerated()
            .filter { $0.offset % 2 == 0 }
            .map(\.element)
            .joined()
    }
}
