import Foundation
import PunkRecordsCore

/// Real ``VideoTranscriptProviding`` implementation for YouTube: scrapes the
/// watch page for its caption track list (the `ytInitialPlayerResponse` JSON
/// blob YouTube embeds in the page — the same public mechanism transcript
/// tools like `yt-dlp`/`youtube-transcript-api` use; there is no
/// authentication-free official captions API), then fetches the chosen
/// track's `timedtext` endpoint and parses its XML cues.
///
/// **Live-network-only, exercised manually.** This hits real YouTube
/// endpoints and depends on page-scraping a JSON shape YouTube doesn't
/// contractually guarantee to keep stable. Per PUNK-zup's validation notes,
/// the default test suite only exercises the PURE parsing halves
/// (``extractCaptionTrackURL(fromWatchPageHTML:)``, ``parseTimedText(xml:)``)
/// against canned fixture strings — never a live request. Smoke-test the live
/// path by hand (or behind a `TEST_RUNNER_PUNKRECORDS_LIVE_EVALS=1`-style
/// opt-in flag, per CLAUDE.md's live-eval convention) before shipping UI that
/// depends on it.
public struct YouTubeTranscriptProvider: VideoTranscriptProviding {
    private let httpClient: any WebHTTPClient
    private let timeout: TimeInterval

    public init(httpClient: any WebHTTPClient = URLSessionWebHTTPClient(), timeout: TimeInterval = 20) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func fetchTranscript(for target: VideoTarget) async throws -> VideoTranscript {
        guard target.provider == .youTube, let watchURL = URL(string: "https://www.youtube.com/watch?v=\(target.videoID)") else {
            throw VideoTranscriptError.transcriptUnavailable(videoID: target.videoID)
        }

        let watchResponse: WebHTTPResponse
        do {
            watchResponse = try await httpClient.get(watchURL, headers: Self.headers, timeout: timeout)
        } catch {
            throw VideoTranscriptError.transport("watch page fetch failed: \(error)")
        }
        let html = watchResponse.text()
        guard let trackURL = Self.extractCaptionTrackURL(fromWatchPageHTML: html) else {
            throw VideoTranscriptError.transcriptUnavailable(videoID: target.videoID)
        }
        let title = Self.extractTitle(fromWatchPageHTML: html)

        let captionResponse: WebHTTPResponse
        do {
            captionResponse = try await httpClient.get(trackURL, headers: Self.headers, timeout: timeout)
        } catch {
            throw VideoTranscriptError.transport("caption track fetch failed: \(error)")
        }
        let cues = Self.parseTimedText(xml: captionResponse.text())
        guard !cues.isEmpty else { throw VideoTranscriptError.transcriptUnavailable(videoID: target.videoID) }

        return VideoTranscript(target: target, title: title, languageCode: nil, cues: cues)
    }

    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept-Language": "en-US,en;q=0.9",
    ]

    // MARK: - Pure parsing (testable without network)

    /// Pulls the first suitable caption track's `baseUrl` out of the watch
    /// page's embedded `"captionTracks":[...]` JSON array (part of
    /// `ytInitialPlayerResponse`). Prefers a manually-authored English track,
    /// then any English track (including auto-generated, `kind: "asr"`),
    /// then whatever track is listed first.
    static func extractCaptionTrackURL(fromWatchPageHTML html: String) -> URL? {
        guard let range = html.range(of: "\"captionTracks\":") else { return nil }
        let tail = html[range.upperBound...]
        guard let arrayStart = tail.firstIndex(of: "["),
              let arrayEnd = matchingBracket(in: tail, openIndex: arrayStart) else { return nil }
        let arrayText = String(tail[arrayStart...arrayEnd])
        guard let data = arrayText.data(using: .utf8),
              let tracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let preferred = tracks.first { isEnglish($0) && ($0["kind"] as? String) != "asr" }
            ?? tracks.first { isEnglish($0) }
            ?? tracks.first
        guard let rawURL = preferred?["baseUrl"] as? String else { return nil }
        return URL(string: rawURL.replacingOccurrences(of: "\\u0026", with: "&"))
    }

    private static func isEnglish(_ track: [String: Any]) -> Bool {
        (track["languageCode"] as? String)?.hasPrefix("en") == true
    }

    /// Pull the watch page's `<title>` (with YouTube's `" - YouTube"` suffix
    /// stripped), used as the transcript's title when present.
    static func extractTitle(fromWatchPageHTML html: String) -> String? {
        guard let start = html.range(of: "<title>"),
              let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex) else {
            return nil
        }
        let raw = String(html[start.upperBound..<end.lowerBound])
        let title = raw.replacingOccurrences(of: " - YouTube", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Parse a YouTube `timedtext` XML response
    /// (`<transcript><text start="1.2" dur="3.4">Hello</text>...</transcript>`)
    /// into cues.
    static func parseTimedText(xml: String) -> [TranscriptCue] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = TimedTextParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.cues
    }

    /// Find the index of the `]` that closes the `[` at `openIndex`,
    /// respecting nesting. Naive (doesn't special-case brackets inside JSON
    /// string literals) — adequate for `captionTracks`, whose values don't
    /// contain literal `[`/`]` in practice.
    private static func matchingBracket(in text: Substring, openIndex: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Collects `<text start dur>...</text>` cues from a `timedtext` XML
/// response. `XMLParser` handles entity decoding (`&amp;`, `&#39;`, ...) for
/// us via `foundCharacters`.
private final class TimedTextParserDelegate: NSObject, XMLParserDelegate {
    private(set) var cues: [TranscriptCue] = []
    private var currentStart: Double?
    private var currentDur: Double?
    private var currentText = ""
    private var inText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "text" else { return }
        inText = true
        currentText = ""
        currentStart = attributeDict["start"].flatMap(Double.init)
        currentDur = attributeDict["dur"].flatMap(Double.init)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "text" else { return }
        inText = false
        defer { currentStart = nil; currentDur = nil; currentText = "" }
        guard let start = currentStart else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cues.append(TranscriptCue(startSeconds: start, endSeconds: currentDur.map { start + $0 }, text: text))
    }
}
