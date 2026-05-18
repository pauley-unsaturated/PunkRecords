import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("MarkdownHTMLRenderer")
struct MarkdownHTMLRendererTests {

    @Test("Headings render as h1/h2 with the expected text")
    func headingsRender() {
        let html = MarkdownHTMLRenderer.renderHTMLFragment(markdown: """
        # Hello
        ## World
        """)
        #expect(html.contains("<h1>Hello</h1>"))
        #expect(html.contains("<h2>World</h2>"))
    }

    @Test("Bold and italic render as strong/em")
    func emphasisRenders() {
        let html = MarkdownHTMLRenderer.renderHTMLFragment(markdown: "This is **bold** and *italic*.")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
    }

    @Test("Frontmatter is stripped before HTML rendering")
    func frontmatterStripped() {
        let markdown = """
        ---
        title: Secret Title
        tags: [a, b]
        ---

        # Body Heading
        Just the body.
        """
        let html = MarkdownHTMLRenderer.renderHTMLDocument(markdown: markdown, title: "Doc Title")
        #expect(!html.contains("Secret Title"), "Frontmatter title should not leak into HTML body")
        #expect(!html.contains("tags: [a, b]"), "Frontmatter should be stripped before rendering")
        #expect(html.contains("<h1>Body Heading</h1>"))
    }

    @Test("Wrapped document includes title in <title> tag")
    func documentTitleSet() {
        let html = MarkdownHTMLRenderer.renderHTMLDocument(markdown: "body", title: "My Note")
        #expect(html.contains("<title>My Note</title>"))
    }

    @Test("Title is HTML-escaped to avoid breaking the document")
    func titleIsEscaped() {
        let html = MarkdownHTMLRenderer.renderHTMLDocument(
            markdown: "body",
            title: "<script>alert('xss')</script>"
        )
        #expect(!html.contains("<script>alert"),
                "Raw script tag must not appear unescaped in the document head")
        #expect(html.contains("&lt;script&gt;"),
                "Title should be HTML-escaped")
    }

    @Test("Wrapped document is a complete HTML document")
    func documentIsWellFormed() {
        let html = MarkdownHTMLRenderer.renderHTMLDocument(markdown: "# X", title: "T")
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("<meta charset=\"UTF-8\">"))
        #expect(html.contains("<article>"))
        #expect(html.contains("</article>"))
        #expect(html.contains("</html>"))
    }

    @Test("Wikilinks survive as literal text (no resolver in HTML export)")
    func wikilinksRenderAsText() {
        // The decision per PUNK-31n acceptance: wikilinks render as visible
        // text — recipients outside the vault have no resolver, so dead
        // anchors would be worse than visible source.
        let html = MarkdownHTMLRenderer.renderHTMLFragment(markdown: "See [[My Note]] for details.")
        #expect(html.contains("[[My Note]]"))
    }

    @Test("Code blocks and inline code render")
    func codeBlocksRender() {
        let html = MarkdownHTMLRenderer.renderHTMLFragment(markdown: """
        Inline `let x = 1`.

        ```swift
        func hi() {}
        ```
        """)
        #expect(html.contains("<code>let x = 1</code>"))
        #expect(html.contains("func hi()"))
        #expect(html.contains("<pre>"))
    }

    @Test("Stylesheet block is embedded so output is self-contained")
    func stylesheetEmbedded() {
        let html = MarkdownHTMLRenderer.renderHTMLDocument(markdown: "x", title: "T")
        #expect(html.contains("<style>"))
        #expect(html.contains("</style>"))
        #expect(!html.contains("<link rel=\"stylesheet\""),
                "Export should be self-contained — no external stylesheet links")
    }

    @Test("Empty markdown produces a valid document with empty article")
    func emptyMarkdown() {
        let html = MarkdownHTMLRenderer.renderHTMLDocument(markdown: "", title: "Empty")
        #expect(html.contains("<title>Empty</title>"))
        #expect(html.contains("<article>"))
    }
}
