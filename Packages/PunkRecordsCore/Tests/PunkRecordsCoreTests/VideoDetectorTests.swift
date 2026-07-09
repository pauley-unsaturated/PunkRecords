import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("VideoDetector — YouTube/Vimeo host + og:type detection and video id extraction")
struct VideoDetectorTests {

    // MARK: - YouTube

    @Test("Detects a youtube.com/watch?v= URL and extracts the video id")
    func youTubeWatchURL() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.provider == .youTube)
        #expect(target?.videoID == "dQw4w9WgXcQ")
    }

    @Test("Detects a youtu.be short URL and extracts the video id")
    func youTubeShortURL() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.provider == .youTube)
        #expect(target?.videoID == "dQw4w9WgXcQ")
    }

    @Test("Detects a youtube.com/shorts/ URL and extracts the video id")
    func youTubeShortsURL() {
        let url = URL(string: "https://www.youtube.com/shorts/abc123XYZ")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.provider == .youTube)
        #expect(target?.videoID == "abc123XYZ")
    }

    @Test("Detects a youtube.com/embed/ URL and extracts the video id")
    func youTubeEmbedURL() {
        let url = URL(string: "https://www.youtube.com/embed/abc123XYZ")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.videoID == "abc123XYZ")
    }

    // MARK: - Vimeo

    @Test("Detects a vimeo.com/{id} URL")
    func vimeoURL() {
        let url = URL(string: "https://vimeo.com/76979871")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.provider == .vimeo)
        #expect(target?.videoID == "76979871")
    }

    @Test("Detects a player.vimeo.com/video/{id} URL")
    func vimeoPlayerURL() {
        let url = URL(string: "https://player.vimeo.com/video/76979871")!
        let target = VideoDetector.detect(url: url, ogType: nil)
        #expect(target?.provider == .vimeo)
        #expect(target?.videoID == "76979871")
    }

    // MARK: - og:type fallback

    @Test("An unrecognized youtube-family subdomain still matches via og:type video")
    func ogTypeFallbackOnYouTubeFamilyHost() {
        let url = URL(string: "https://gaming.youtube.com/watch?v=abc123XYZ")!
        let target = VideoDetector.detect(url: url, ogType: "video.other")
        #expect(target?.provider == .youTube)
    }

    @Test("og:type video on a totally unrelated host does NOT produce a video target")
    func ogTypeAloneOnUnrelatedHostDoesNotMatch() {
        let url = URL(string: "https://news.example.com/watch-this-clip")!
        let target = VideoDetector.detect(url: url, ogType: "video.other")
        #expect(target == nil)
    }

    // MARK: - Negative cases

    @Test("A normal article URL is not detected as a video")
    func normalArticleNotDetected() {
        let url = URL(string: "https://blog.example.com/great-article")!
        #expect(VideoDetector.detect(url: url, ogType: "article") == nil)
    }

    @Test("A YouTube host with no extractable video id yields no target")
    func youTubeHostWithoutID() {
        let url = URL(string: "https://www.youtube.com/feed/trending")!
        #expect(VideoDetector.detect(url: url, ogType: nil) == nil)
    }

    // MARK: - Signals convenience

    @Test("detect(signals:) tries the requested URL before the final (post-redirect) URL")
    func detectFromSignalsPrefersRequestedURL() {
        let signals = URLIngestSignals(
            requestedURL: URL(string: "https://youtu.be/dQw4w9WgXcQ")!,
            finalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        )
        let target = VideoDetector.detect(signals: signals)
        #expect(target?.videoID == "dQw4w9WgXcQ")
    }
}
