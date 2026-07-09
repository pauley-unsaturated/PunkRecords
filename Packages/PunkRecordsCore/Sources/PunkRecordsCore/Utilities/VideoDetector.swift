import Foundation

/// Detects a YouTube/Vimeo video URL and extracts its provider-specific video
/// id, per PUNK-zup's failure mode #1. Pure URL inspection — no network.
///
/// Detection is "host match, OR `og:type` starting with `video` on a host
/// that still plausibly belongs to that provider's domain family" (rather
/// than `og:type` alone triggering a match on ANY host). A bare `og:type`
/// match with an unrecognized host can't produce a ``VideoTarget`` anyway —
/// there's no provider to fetch a transcript from — so treating it as a video
/// route would just trade one kind of "nothing to summarize" for another.
/// This still satisfies the "host match or og:type video" detection rule for
/// provider subdomains this list doesn't enumerate explicitly.
public enum VideoDetector {
    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
    ]
    private static let youTubeShortHost = "youtu.be"
    private static let vimeoHosts: Set<String> = ["vimeo.com", "www.vimeo.com"]
    private static let vimeoPlayerHost = "player.vimeo.com"

    /// Detect from ``URLIngestSignals``: tries the originally-requested URL
    /// first (video routing shouldn't require a fetch at all), then the final
    /// (post-redirect) URL.
    public static func detect(signals: URLIngestSignals) -> VideoTarget? {
        detect(url: signals.requestedURL, ogType: signals.ogType)
            ?? detect(url: signals.finalURL, ogType: signals.ogType)
    }

    /// Detect from a single URL plus an optional `og:type` hint.
    public static func detect(url: URL, ogType: String?) -> VideoTarget? {
        guard let host = url.host?.lowercased() else { return nil }
        let looksLikeVideoByOGType = ogType?.lowercased().hasPrefix("video") ?? false

        if host == youTubeShortHost || youTubeHosts.contains(host)
            || (looksLikeVideoByOGType && host.contains("youtube")) {
            if let id = youTubeVideoID(from: url) {
                return VideoTarget(provider: .youTube, videoID: id, sourceURL: url)
            }
        }
        if host == vimeoPlayerHost || vimeoHosts.contains(host)
            || (looksLikeVideoByOGType && host.contains("vimeo")) {
            if let id = vimeoVideoID(from: url) {
                return VideoTarget(provider: .vimeo, videoID: id, sourceURL: url)
            }
        }
        return nil
    }

    // MARK: - Id extraction

    static func youTubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }

        if host == youTubeShortHost {
            guard let id = segments.first, !id.isEmpty else { return nil }
            return id
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !value.isEmpty {
            return value
        }
        if segments.count >= 2, ["shorts", "embed", "live"].contains(segments[0].lowercased()) {
            return segments[1]
        }
        return nil
    }

    static func vimeoVideoID(from url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let host = url.host?.lowercased() else { return nil }
        if host == vimeoPlayerHost {
            guard segments.count >= 2, segments[0].lowercased() == "video" else { return nil }
            return segments[1]
        }
        guard let first = segments.first, !first.isEmpty else { return nil }
        return first
    }
}
