import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("WebHeadings — heading model + anchor assignment")
struct WebHeadingsTests {

    @Test("Generates slug anchors for headings without ids")
    func generatesAnchors() {
        let raw = [
            WebHeadings.RawHeading(level: 1, text: "Introduction"),
            WebHeadings.RawHeading(level: 2, text: "Getting Started"),
        ]
        let headings = WebHeadings.build(from: raw)
        #expect(headings.count == 2)
        #expect(headings[0] == WebHeading(level: 1, text: "Introduction", anchorID: "introduction"))
        #expect(headings[1] == WebHeading(level: 2, text: "Getting Started", anchorID: "getting-started"))
    }

    @Test("Preserves a source element's own id as the anchor")
    func preservesSourceID() {
        let raw = [WebHeadings.RawHeading(level: 2, text: "Install", anchorID: "install-section")]
        let headings = WebHeadings.build(from: raw)
        #expect(headings[0].anchorID == "install-section")
    }

    @Test("Drops headings outside h1–h3 and blank text")
    func filtersLevelsAndBlanks() {
        let raw = [
            WebHeadings.RawHeading(level: 1, text: "Kept"),
            WebHeadings.RawHeading(level: 4, text: "Too deep"),
            WebHeadings.RawHeading(level: 2, text: "   "),
            WebHeadings.RawHeading(level: 0, text: "Bad level"),
        ]
        let headings = WebHeadings.build(from: raw)
        #expect(headings.map(\.text) == ["Kept"])
    }

    @Test("Duplicate heading texts get unique anchors")
    func uniqueAnchors() {
        let raw = [
            WebHeadings.RawHeading(level: 2, text: "Notes"),
            WebHeadings.RawHeading(level: 2, text: "Notes"),
            WebHeadings.RawHeading(level: 3, text: "Notes"),
        ]
        let anchors = WebHeadings.build(from: raw).map(\.anchorID)
        #expect(anchors == ["notes", "notes-2", "notes-3"])
    }

    @Test("A generated slug that collides with a preserved id is disambiguated")
    func generatedCollidesWithPreserved() {
        let raw = [
            WebHeadings.RawHeading(level: 2, text: "Overview", anchorID: "summary"),
            WebHeadings.RawHeading(level: 2, text: "Summary"),
        ]
        let anchors = WebHeadings.build(from: raw).map(\.anchorID)
        #expect(anchors == ["summary", "summary-2"])
    }

    @Test("Trims heading text")
    func trimsText() {
        let raw = [WebHeadings.RawHeading(level: 1, text: "  Spaced Title  ")]
        #expect(WebHeadings.build(from: raw)[0].text == "Spaced Title")
    }

    @Test("Extracts h1–h3 from markdown, ignoring code fences")
    func fromMarkdown() {
        let markdown = """
        # Title
        Some text.
        ## Section One
        ```
        # not a heading
        ```
        ### Sub
        #### Too deep
        """
        let raw = WebHeadings.rawHeadings(fromMarkdown: markdown)
        #expect(raw.map(\.text) == ["Title", "Section One", "Sub"])
        #expect(raw.allSatisfy { $0.anchorID == nil })
    }
}
