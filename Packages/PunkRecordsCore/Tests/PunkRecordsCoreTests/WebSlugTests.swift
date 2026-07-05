import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebSlug — anchor/filename slug generation")
struct WebSlugTests {

    @Test("Lowercases and hyphenates words")
    func basic() {
        #expect(WebSlug.slug(for: "Getting Started With Swift") == "getting-started-with-swift")
    }

    @Test("Collapses punctuation and whitespace runs to single hyphens")
    func punctuation() {
        #expect(WebSlug.slug(for: "Hello,   World!!!  —  Again") == "hello-world-again")
        #expect(WebSlug.slug(for: "a/b\\c:d") == "a-b-c-d")
    }

    @Test("Trims leading and trailing separators")
    func trimEdges() {
        #expect(WebSlug.slug(for: "  ...Leading and trailing...  ") == "leading-and-trailing")
        #expect(WebSlug.slug(for: "#hashtag#") == "hashtag")
    }

    @Test("Folds diacritics to ASCII")
    func unicodeFolding() {
        #expect(WebSlug.slug(for: "Café Déjà Vu") == "cafe-deja-vu")
        #expect(WebSlug.slug(for: "Piñata Niño") == "pinata-nino")
    }

    @Test("Non-transliterable scripts fall back to 'section'")
    func nonLatinFallback() {
        #expect(WebSlug.slug(for: "日本語") == "section")
        #expect(WebSlug.slug(for: "") == "section")
        #expect(WebSlug.slug(for: "!!!") == "section")
    }

    @Test("Keeps digits")
    func digits() {
        #expect(WebSlug.slug(for: "Top 10 Tips for 2026") == "top-10-tips-for-2026")
    }

    @Test("Duplicate texts get numeric suffixes in order")
    func uniqueSlugs() {
        let slugs = WebSlug.uniqueSlugs(for: ["Intro", "Intro", "Setup", "Intro"])
        #expect(slugs == ["intro", "intro-2", "setup", "intro-3"])
    }

    @Test("disambiguate appends the next free suffix")
    func disambiguate() {
        #expect(WebSlug.disambiguate("intro", taken: []) == "intro")
        #expect(WebSlug.disambiguate("intro", taken: ["intro"]) == "intro-2")
        #expect(WebSlug.disambiguate("intro", taken: ["intro", "intro-2"]) == "intro-3")
    }

    @Test("URL slug uses host + path, dropping query and fragment")
    func urlSlug() {
        let url = URL(string: "https://example.com/blog/My-Post?ref=x#frag")!
        #expect(WebSlug.slug(forURL: url) == "example-com-blog-my-post")
    }

    @Test("URL slug for a bare host")
    func urlSlugBareHost() {
        let url = URL(string: "https://www.example.com/")!
        #expect(WebSlug.slug(forURL: url) == "www-example-com")
    }
}
