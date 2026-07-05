import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("ReadabilityExtractor — Tier 1 offline extraction")
struct ReadabilityExtractorTests {

    private let extractor = ReadabilityExtractor()
    private let baseURL = URL(string: "https://blog.example.com/great-article")!

    // MARK: - Fixtures

    private static let articleHTML = """
    <!DOCTYPE html><html><head>
      <title>The Great Article — My Tech Blog</title>
      <meta name="author" content="Ada Lovelace">
      <link rel="canonical" href="https://blog.example.com/great-article">
    </head><body>
      <header><nav>Home About Contact</nav></header>
      <div class="sidebar">
        <ul><li><a href="/one">Sidebar One</a></li><li><a href="/two">Sidebar Two</a></li></ul>
      </div>
      <article class="post content">
        <h1 id="top">The Great Article</h1>
        <p>This is the first substantial paragraph of the article, containing enough words,
           commas, and prose to score comfortably above Readability's content threshold.</p>
        <h2>Background</h2>
        <p>Here is a second paragraph, also fairly long, discussing the background of the topic
           in some depth, with several clauses, commas, and supporting detail throughout.</p>
        <h3 id="details">Fine Details</h3>
        <p>A third paragraph with <a href="/ref">a reference link</a>, some <strong>bold</strong>
           text, and <em>emphasis</em>, followed by a short list of items.</p>
        <ul><li>First item</li><li>Second item</li></ul>
      </article>
      <footer class="footer">Copyright 2026 SecretFooterText</footer>
    </body></html>
    """

    private static let sparseHTML = """
    <!DOCTYPE html><html><head><title>Loading…</title></head>
    <body><div id="root"></div><script>window.render()</script></body></html>
    """

    private static let malformedHTML = """
    <html><body><article><h1>Broken Heading
      <p>Paragraph one is deliberately long enough, with commas and words, to be scored as a
         real content candidate by the algorithm here.
      <p>Second paragraph, also comfortably long, with commas and multiple clauses, so the
         article body is unambiguously detected.
    </article>
    """

    // MARK: - Article-like

    @Test("Extracts title, stripping the site-name suffix")
    func articleTitle() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        #expect(article.title == "The Great Article")
    }

    @Test("Extracts byline and canonical URL")
    func articleMetadata() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        #expect(article.byline == "Ada Lovelace")
        #expect(article.canonicalURL == URL(string: "https://blog.example.com/great-article"))
    }

    @Test("Keeps article prose and drops nav/sidebar/footer boilerplate")
    func articleBoilerplateStripped() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        #expect(article.contentMarkdown.contains("first substantial paragraph"))
        #expect(article.contentMarkdown.contains("second paragraph"))
        #expect(!article.contentMarkdown.contains("Sidebar One"))
        #expect(!article.contentMarkdown.contains("SecretFooterText"))
        #expect(!article.contentMarkdown.contains("Home About Contact"))
    }

    @Test("Renders headings, list, link, and emphasis as markdown")
    func articleMarkdownStructure() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        let md = article.contentMarkdown
        #expect(md.contains("## Background"))
        #expect(md.contains("### Fine Details"))
        #expect(md.contains("- First item"))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*emphasis*"))
        #expect(md.contains("[a reference link](https://blog.example.com/ref)"))
    }

    @Test("Preserves heading ids and levels as raw headings")
    func articleHeadingsPreserved() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        #expect(article.rawHeadings == [
            WebHeadings.RawHeading(level: 1, text: "The Great Article", anchorID: "top"),
            WebHeadings.RawHeading(level: 2, text: "Background", anchorID: nil),
            WebHeadings.RawHeading(level: 3, text: "Fine Details", anchorID: "details"),
        ])
    }

    @Test("Article text length is well above the escalation threshold")
    func articleIsRich() throws {
        let article = try extractor.extract(html: Self.articleHTML, baseURL: baseURL)
        #expect(article.textLength >= WebFetchTierPolicy.minReadableContentLength)
        #expect(!WebFetchTierPolicy.shouldEscalateToBrowser(
            tier1CharacterCount: article.textLength, isProbablyReaderable: true))
    }

    // MARK: - Sparse

    @Test("A JS-shell page yields little content and would escalate")
    func sparsePageEscalates() throws {
        let article = try extractor.extract(html: Self.sparseHTML, baseURL: baseURL)
        #expect(article.textLength < WebFetchTierPolicy.minReadableContentLength)
        #expect(WebFetchTierPolicy.shouldEscalateToBrowser(
            tier1CharacterCount: article.textLength, isProbablyReaderable: true))
        #expect(!article.contentMarkdown.contains("window.render"))
    }

    // MARK: - Malformed

    @Test("Malformed HTML is parsed leniently without throwing")
    func malformedIsRecovered() throws {
        let article = try extractor.extract(html: Self.malformedHTML, baseURL: baseURL)
        #expect(article.contentMarkdown.contains("Paragraph one"))
        #expect(article.contentMarkdown.contains("Second paragraph"))
        #expect(article.rawHeadings.contains { $0.text.contains("Broken Heading") })
    }

    @Test("Empty input does not crash")
    func emptyInput() throws {
        let article = try extractor.extract(html: "", baseURL: baseURL)
        #expect(article.contentMarkdown.isEmpty)
        #expect(article.rawHeadings.isEmpty)
    }
}
