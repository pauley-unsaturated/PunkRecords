import Testing
@testable import PunkRecordsCore

@Suite("Markdown Parser Tests")
struct MarkdownParserTests {
    let parser = MarkdownParser()

    @Test("Parses YAML frontmatter")
    func frontmatter() {
        let content = """
        ---
        id: 550e8400-e29b-41d4-a716-446655440000
        tags: [swift, ai]
        title: Test Note
        ---

        # My Note

        Content here.
        """
        let (fm, body) = parser.parseFrontmatter(from: content)
        #expect(fm["id"] == "550e8400-e29b-41d4-a716-446655440000")
        #expect(fm["title"] == "Test Note")
        #expect(body.contains("# My Note"))
    }

    @Test("Handles missing frontmatter gracefully")
    func noFrontmatter() {
        let content = "# Just a heading\n\nSome content."
        let (fm, body) = parser.parseFrontmatter(from: content)
        #expect(fm.isEmpty)
        #expect(body == content)
    }

    @Test("Parses tags from frontmatter")
    func tags() {
        let tags = parser.parseTags(from: ["tags": "[swift, ai, research]"])
        #expect(tags == ["swift", "ai", "research"])
    }

    @Test("Parses wikilinks")
    func wikilinks() {
        let content = "See [[Note A]] and [[Note B|displayed]]."
        let links = parser.parseWikilinks(from: content)
        #expect(links.count == 2)
        #expect(links[0].target == "Note A")
        #expect(links[0].displayText == nil)
        #expect(links[1].target == "Note B")
        #expect(links[1].displayText == "displayed")
    }

    @Test("Parses markdown links")
    func markdownLinks() {
        let content = "Read [this article](https://example.com) and [notes](notes/other.md)."
        let links = parser.parseMarkdownLinks(from: content)
        #expect(links.count == 2)
        #expect(links[0].text == "this article")
        #expect(links[0].url == "https://example.com")
        #expect(links[1].url == "notes/other.md")
    }

    @Test("Full parse produces correct document")
    func fullParse() {
        let content = """
        ---
        id: 550e8400-e29b-41d4-a716-446655440000
        tags: [swift]
        ---

        # Test Document

        See [[Related Note]] for details.
        """
        let parsed = parser.parse(content: content, filename: "test.md")
        #expect(parsed.title == "Test Document")
        #expect(parsed.tags == ["swift"])
        #expect(parsed.wikilinks.count == 1)
        #expect(parsed.wikilinks[0].target == "Related Note")
        #expect(!parsed.needsIDAssigned)
    }

    @Test("Document without ID gets needsIDAssigned flag")
    func needsID() {
        let content = "# No Frontmatter\n\nJust content."
        let parsed = parser.parse(content: content, filename: "test.md")
        #expect(parsed.needsIDAssigned)
    }

    @Test("Generates valid frontmatter")
    func generateFrontmatter() {
        let id = DocumentID()
        let fm = parser.generateFrontmatter(id: id, tags: ["swift", "ai"])
        #expect(fm.contains("id: \(id.uuidString)"))
        #expect(fm.contains("tags: [swift, ai]"))
        #expect(fm.hasPrefix("---"))
        #expect(fm.hasSuffix("---"))
    }

    @Test("Handles empty documents")
    func emptyDocument() {
        let parsed = parser.parse(content: "", filename: "empty.md")
        #expect(parsed.title == "empty")
        #expect(parsed.tags.isEmpty)
        #expect(parsed.wikilinks.isEmpty)
    }
}
