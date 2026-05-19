import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("CanonicalMarkdownParser Tests")
struct CanonicalMarkdownParserTests {
    let parser = CanonicalMarkdownParser()

    @Test("Empty document parses with empty summary")
    func emptyDocument() {
        let summary = parser.summary(of: "")
        #expect(summary.counts.headings == 0)
        #expect(summary.counts.paragraphs == 0)
        #expect(summary.hasFrontmatter == false)
    }

    @Test("Headings and paragraphs are counted")
    func headingsAndParagraphs() {
        let source = """
        # Title

        Some paragraph text.

        ## Subtitle

        Another paragraph.
        """
        let summary = parser.summary(of: source)
        #expect(summary.counts.headings == 2)
        #expect(summary.counts.paragraphs == 2)
    }

    @Test("Code blocks counted")
    func codeBlocks() {
        let source = """
        ```swift
        let x = 1
        ```
        """
        let summary = parser.summary(of: source)
        #expect(summary.counts.codeBlocks == 1)
    }

    @Test("Lists, blockquotes, thematic breaks parse")
    func mixedConstructs() {
        let source = """
        > A quotation.

        - one
        - two
        - three

        ---

        Paragraph after.
        """
        let summary = parser.summary(of: source)
        #expect(summary.counts.blockQuotes == 1)
        #expect(summary.counts.lists == 1)
        #expect(summary.counts.thematicBreaks == 1)
        #expect(summary.counts.paragraphs >= 1)
    }

    @Test("GFM tables parse")
    func gfmTable() {
        let source = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let summary = parser.summary(of: source)
        #expect(summary.counts.tables == 1)
    }

    @Test("Detects YAML frontmatter prefix")
    func detectsFrontmatter() {
        let source = """
        ---
        id: foo
        ---

        # Title
        """
        let summary = parser.summary(of: source)
        #expect(summary.hasFrontmatter)
    }

    @Test("Pathological input does not crash")
    func pathological() {
        let weird = String(repeating: "*[`#\n\n", count: 200)
        _ = parser.parse(weird)
        _ = parser.summary(of: weird)
    }
}
