import Foundation

/// Detects transcript/comment-thread-shaped content, per PUNK-zup's failure
/// mode #7: a page whose body is mostly `Speaker: line` turns (an interview
/// transcript, a chat log, a forum thread) rather than article prose. Pure
/// text analysis — no HTML parsing, no LLM call.
///
/// Heuristic: a line "looks like a speaker line" when it starts with (an
/// optional `[HH:MM(:SS)]` timestamp, then) 1–3 capitalized words followed by
/// `: ` — e.g. `"Alice: I think we should ship it."` or `"[00:12:03] Bob:
/// Agreed."`. `looksLikeTranscript` requires BOTH a minimum absolute count and
/// a minimum density of such lines, so a normal article with one aside like
/// `"Editor's note: ..."` doesn't false-positive.
public enum TranscriptHeuristic {
    /// Minimum number of matching lines before a document is even considered.
    public static let minSpeakerLines = 6
    /// Minimum fraction of non-blank lines that must match.
    public static let minSpeakerLineDensity = 0.25

    private static let speakerLinePattern =
        "^(?:\\[\\d{1,2}:\\d{2}(?::\\d{2})?\\]\\s*)?[A-Z][\\w.'-]{0,30}(?:\\s[A-Z][\\w.'-]{0,30}){0,2}:\\s+\\S"
    private static let speakerLineRegex = try! NSRegularExpression(pattern: speakerLinePattern)

    /// Fraction (0...1) of non-blank lines in `text` that look like a speaker
    /// line. `0` for empty/blank input.
    public static func speakerLineDensity(in text: String) -> Double {
        let lines = nonBlankLines(in: text)
        guard !lines.isEmpty else { return 0 }
        let matches = lines.filter(isSpeakerLine).count
        return Double(matches) / Double(lines.count)
    }

    /// Whether `text` looks like a transcript/comment-thread rather than
    /// article prose — both ``minSpeakerLines`` and ``minSpeakerLineDensity``
    /// must be satisfied.
    public static func looksLikeTranscript(_ text: String) -> Bool {
        let lines = nonBlankLines(in: text)
        guard !lines.isEmpty else { return false }
        let matches = lines.filter(isSpeakerLine).count
        guard matches >= minSpeakerLines else { return false }
        return Double(matches) / Double(lines.count) >= minSpeakerLineDensity
    }

    static func isSpeakerLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return speakerLineRegex.firstMatch(in: line, range: range) != nil
    }

    static func nonBlankLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
