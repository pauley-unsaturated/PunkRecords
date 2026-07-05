import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("VaultPaths — web content cache paths")
struct WebCachePathTests {

    @Test("Cache directory lives under a visible Web/_cache tree")
    func directory() {
        #expect(VaultPaths.webCacheDirectory == "Web/_cache")
    }

    @Test("Cache path for a slug is Web/_cache/{slug}.html")
    func pathForSlug() {
        #expect(VaultPaths.webCachePath(forSlug: "example-com-post") == "Web/_cache/example-com-post.html")
    }

    @Test("Empty slug falls back so the path is never a bare .html")
    func emptySlug() {
        #expect(VaultPaths.webCachePath(forSlug: "") == "Web/_cache/section.html")
    }

    @Test("Cache path for a URL derives a stable slug")
    func pathForURL() {
        let url = URL(string: "https://example.com/blog/My-Post?x=1")!
        #expect(VaultPaths.webCachePath(forURL: url) == "Web/_cache/example-com-blog-my-post.html")
    }

    @Test("Same URL maps to the same cache path across calls")
    func stable() {
        let url = URL(string: "https://example.com/a/b")!
        #expect(VaultPaths.webCachePath(forURL: url) == VaultPaths.webCachePath(forURL: url))
    }
}
