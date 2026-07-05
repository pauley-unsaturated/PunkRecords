import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("ReadabilityResultMapper — Tier 2 JS-result → model mapping")
struct ReadabilityResultMapperTests {

    private let baseURL = URL(string: "https://example.com/article")!

    private func result(html: String, title: String? = "Title", byline: String? = nil, text: String = "") -> ReadabilityResult {
        ReadabilityResult(title: title, byline: byline, contentHTML: html, textContent: text)
    }

    @Test("Maps Readability.js title and byline through")
    func titleAndByline() throws {
        let article = try ReadabilityResultMapper.map(
            result(html: "<p>Body paragraph.</p>", title: "Rendered Title", byline: "By Grace Hopper"),
            baseURL: baseURL
        )
        #expect(article.title == "Rendered Title")
        #expect(article.byline == "By Grace Hopper")
    }

    @Test("Falls back to the first heading when no title is present")
    func titleFallback() throws {
        let article = try ReadabilityResultMapper.map(
            result(html: "<h1>Heading Title</h1><p>Body.</p>", title: nil),
            baseURL: baseURL
        )
        #expect(article.title == "Heading Title")
    }

    @Test("Converts headings, preserving ids as raw anchors")
    func headings() throws {
        let html = """
        <h1 id="intro">Intro</h1><p>Text.</p><h2>Details</h2><p>More.</p><h3 id="x">Sub</h3>
        """
        let article = try ReadabilityResultMapper.map(result(html: html), baseURL: baseURL)
        #expect(article.rawHeadings == [
            WebHeadings.RawHeading(level: 1, text: "Intro", anchorID: "intro"),
            WebHeadings.RawHeading(level: 2, text: "Details", anchorID: nil),
            WebHeadings.RawHeading(level: 3, text: "Sub", anchorID: "x"),
        ])
    }

    @Test("Renders paragraphs, emphasis, links, and lists")
    func markdownStructure() throws {
        let html = """
        <p>A paragraph with <strong>bold</strong>, <em>italic</em>, and
        <a href="/rel">a link</a>.</p>
        <ul><li>Alpha</li><li>Beta</li></ul>
        <ol><li>One</li><li>Two</li></ol>
        """
        let md = try ReadabilityResultMapper.map(result(html: html), baseURL: baseURL).contentMarkdown
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("[a link](https://example.com/rel)"))
        #expect(md.contains("- Alpha"))
        #expect(md.contains("- Beta"))
        #expect(md.contains("1. One"))
        #expect(md.contains("2. Two"))
    }

    @Test("Renders blockquotes and code blocks")
    func blockquoteAndCode() throws {
        let html = """
        <blockquote><p>Quoted wisdom.</p></blockquote>
        <pre><code>let x = 1</code></pre>
        """
        let md = try ReadabilityResultMapper.map(result(html: html), baseURL: baseURL).contentMarkdown
        #expect(md.contains("> Quoted wisdom."))
        #expect(md.contains("```"))
        #expect(md.contains("let x = 1"))
    }

    @Test("Renders inline code and images")
    func inlineCodeAndImage() throws {
        let html = "<p>Use <code>map(_:)</code> here.</p><p><img src=\"/img/a.png\" alt=\"Chart\"></p>"
        let md = try ReadabilityResultMapper.map(result(html: html), baseURL: baseURL).contentMarkdown
        #expect(md.contains("`map(_:)`"))
        #expect(md.contains("![Chart](https://example.com/img/a.png)"))
    }

    @Test("Renders nested lists with indentation")
    func nestedLists() throws {
        let html = "<ul><li>Top<ul><li>Nested</li></ul></li></ul>"
        let md = try ReadabilityResultMapper.map(result(html: html), baseURL: baseURL).contentMarkdown
        #expect(md.contains("- Top"))
        #expect(md.contains("  - Nested"))
    }

    @Test("Text length uses Readability's plain textContent when provided")
    func textLengthFromTextContent() throws {
        let article = try ReadabilityResultMapper.map(
            result(html: "<p>Short.</p>", text: String(repeating: "a", count: 400)),
            baseURL: baseURL
        )
        #expect(article.textLength == 400)
    }
}
