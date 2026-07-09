import Foundation

/// Bridges a fetched ``VideoTranscript`` (PUNK-zup failure mode #1) into the
/// existing ``WebSummaryPrompt``/``WebSummaryPostProcessor`` pipeline: builds
/// a transcript-shaped ``WebContent`` to prompt against, and a
/// ``WebSummaryPostProcessor/CitationLinkResolver`` that maps a citation's
/// `supporting_text` back to the transcript cue it came from and emits a
/// `&t=Ns` timestamp deep link instead of a `#:~:text=` fragment.
public enum VideoSummaryRenderer {
    /// Build the ``WebContent`` to feed ``WebSummaryPrompt/build(content:variant:languageHint:)``:
    /// `contentMarkdown` is the transcript's full text (cues space-joined, see
    /// ``VideoTranscript/fullText``), `tier` is ``WebFetchTier/videoTranscript``.
    /// No headings — timestamp citations don't need a heading anchor.
    public static func makeContent(
        from transcript: VideoTranscript,
        sourceURL: URL,
        extractedAt: Date
    ) -> WebContent {
        WebContent(
            title: transcript.title ?? sourceURL.absoluteString,
            byline: nil,
            contentMarkdown: transcript.fullText,
            headings: [],
            extractedAt: extractedAt,
            tier: .videoTranscript,
            sourceURL: sourceURL,
            canonicalURL: nil
        )
    }

    /// A ``WebSummaryPostProcessor/CitationLinkResolver`` that resolves a
    /// citation's `supporting_text` to the cue containing it (first
    /// occurrence, matching ``TextFragmentBuilder``'s general
    /// first-occurrence-wins philosophy for ambiguous matches — a coarse
    /// timestamp jump doesn't need the inline disambiguation an on-page text
    /// fragment does) and builds a `videoURL` + `&t=Ns` deep link. Falls back
    /// to the bare `videoURL` (unresolved) when `supporting_text` isn't found
    /// in the transcript at all.
    public static func citationLinkResolver(
        transcript: VideoTranscript,
        videoURL: URL
    ) -> WebSummaryPostProcessor.CitationLinkResolver {
        let cueRanges = cueOffsetRanges(for: transcript.cues)
        let fullText = transcript.fullText
        return { citation in
            guard let seconds = resolveSeconds(
                for: citation.supportingText,
                fullText: fullText,
                cueRanges: cueRanges
            ) else {
                return .init(url: videoURL, isResolved: false)
            }
            return .init(url: deepLink(base: videoURL, atSeconds: seconds), isResolved: true)
        }
    }

    // MARK: - Cue offset resolution

    /// The character range each cue occupies within ``VideoTranscript/fullText``,
    /// in cue order (cues are space-joined, matching `fullText`'s construction).
    static func cueOffsetRanges(for cues: [TranscriptCue]) -> [(range: Range<Int>, startSeconds: Double)] {
        var ranges: [(Range<Int>, Double)] = []
        var offset = 0
        for (index, cue) in cues.enumerated() {
            let length = cue.text.count
            ranges.append((offset..<(offset + length), cue.startSeconds))
            offset += length
            if index < cues.count - 1 { offset += 1 } // the joining space
        }
        return ranges
    }

    /// Find `supportingText`'s first occurrence in `fullText` and return the
    /// `startSeconds` of the cue it falls within, or `nil` if not found in any
    /// cue.
    static func resolveSeconds(
        for supportingText: String,
        fullText: String,
        cueRanges: [(range: Range<Int>, startSeconds: Double)]
    ) -> Int? {
        let needle = supportingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let matchRange = fullText.range(of: needle) else { return nil }
        let startOffset = fullText.distance(from: fullText.startIndex, to: matchRange.lowerBound)
        guard let match = cueRanges.first(where: { $0.range.contains(startOffset) }) else {
            // The match may land exactly on a trailing boundary (e.g. the
            // very last character of the transcript); fall back to the last
            // cue whose range starts at or before the match.
            return cueRanges.last(where: { $0.range.lowerBound <= startOffset }).map { Int($0.startSeconds) }
        }
        return Int(match.startSeconds)
    }

    // MARK: - Deep link

    /// Build a `videoURL` deep link with a `t=<seconds>s` query item appended
    /// (preserving any existing query items, e.g. `v=`), per PUNK-zup's
    /// `&t=Ns` timestamp-anchor requirement.
    static func deepLink(base: URL, atSeconds seconds: Int) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: "\(seconds)s"))
        components.queryItems = items
        return components.url ?? base
    }
}
