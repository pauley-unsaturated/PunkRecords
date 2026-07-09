import Foundation

/// One caption/auto-caption cue: the text spoken starting at `startSeconds`.
/// `endSeconds` is informational only — citation resolution (see
/// ``VideoSummaryRenderer``) anchors on `startSeconds`, matching how YouTube's
/// own `&t=Ns` deep links work (jump to a moment, not a range).
public struct TranscriptCue: Sendable, Equatable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double?
    public let text: String

    public init(startSeconds: Double, endSeconds: Double? = nil, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

/// A fetched video transcript: every cue, in order, plus enough metadata to
/// build a citable ``WebContent``-equivalent (see ``VideoSummaryRenderer``).
public struct VideoTranscript: Sendable, Equatable, Codable {
    public let target: VideoTarget
    public let title: String?
    /// BCP-47-ish language code of the transcript track, when known (e.g. an
    /// auto-generated English caption track is `"en"`).
    public let languageCode: String?
    public let cues: [TranscriptCue]

    public init(target: VideoTarget, title: String?, languageCode: String?, cues: [TranscriptCue]) {
        self.target = target
        self.title = title
        self.languageCode = languageCode
        self.cues = cues
    }

    /// Every cue's text, space-joined, in cue order. This is the "body text"
    /// ``VideoSummaryRenderer`` feeds to the summary prompt in place of
    /// article markdown — a citation's `supporting_text` is matched against
    /// this string, then mapped back to the cue (and hence timestamp) it came
    /// from.
    public var fullText: String { cues.map(\.text).joined(separator: " ") }
}

/// Errors a ``VideoTranscriptProviding`` implementation can throw.
public enum VideoTranscriptError: Error, Sendable, Equatable {
    /// The video has no available transcript/captions (disabled by the
    /// uploader, or the provider genuinely has none).
    case transcriptUnavailable(videoID: String)
    /// The transport failed (network, non-2xx, malformed response).
    case transport(String)
}

/// Fetches a transcript for a detected video. The real implementation
/// (`YouTubeTranscriptProvider`, Infra) calls YouTube's public
/// timedtext/auto-caption endpoints over the network; tests use a
/// deterministic in-memory double instead — see PUNK-zup's validation notes
/// for why the live provider is exercised manually rather than in the
/// default test suite.
public protocol VideoTranscriptProviding: Sendable {
    func fetchTranscript(for target: VideoTarget) async throws -> VideoTranscript
}
