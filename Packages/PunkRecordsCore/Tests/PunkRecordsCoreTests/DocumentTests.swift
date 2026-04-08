import Testing
@testable import PunkRecordsCore

@Suite("Document Tests")
struct DocumentTests {
    @Test("Title derived from H1 heading")
    func titleFromH1() {
        let title = Document.deriveTitle(
            content: "# My Great Note\n\nSome content here.",
            frontmatter: [:],
            filename: "fallback.md"
        )
        #expect(title == "My Great Note")
    }

    @Test("Title falls back to frontmatter title")
    func titleFromFrontmatter() {
        let title = Document.deriveTitle(
            content: "Some content without a heading.",
            frontmatter: ["title": "Frontmatter Title"],
            filename: "fallback.md"
        )
        #expect(title == "Frontmatter Title")
    }

    @Test("Title falls back to filename")
    func titleFromFilename() {
        let title = Document.deriveTitle(
            content: "Some content without a heading.",
            frontmatter: [:],
            filename: "my-note.md"
        )
        #expect(title == "my-note")
    }

    @Test("Tags are normalized to lowercase")
    func tagNormalization() {
        let doc = Document(
            title: "Test",
            content: "",
            path: "test.md",
            tags: ["Swift", " AI ", "Research"]
        )
        #expect(doc.tags == ["swift", "ai", "research"])
    }

    @Test("Equality is by ID, not content")
    func equalityByID() {
        let id = DocumentID()
        let doc1 = Document(id: id, title: "A", content: "Content A", path: "a.md")
        let doc2 = Document(id: id, title: "B", content: "Content B", path: "b.md")
        #expect(doc1 == doc2)
    }
}
