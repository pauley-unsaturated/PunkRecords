import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("HeadingOutline Tests")
struct HeadingOutlineTests {
    @Test("Parses levels and titles in document order")
    func levelsAndTitles() {
        let text = "# One\n## Two\n### Three\n# Four"
        let nodes = HeadingOutline.parse(text)
        #expect(nodes.map(\.level) == [1, 2, 3, 1])
        #expect(nodes.map(\.title) == ["One", "Two", "Three", "Four"])
    }

    @Test("Heading path reflects ancestry")
    func paths() {
        let text = "# Guide\n## Setup\n### Install\n## Usage\n# Other"
        let nodes = HeadingOutline.parse(text)
        #expect(nodes[0].path == ["Guide"])
        #expect(nodes[1].path == ["Guide", "Setup"])
        #expect(nodes[2].path == ["Guide", "Setup", "Install"])
        #expect(nodes[3].path == ["Guide", "Usage"])   // pops back to H1 Guide
        #expect(nodes[4].path == ["Other"])
    }

    @Test("Section range spans the full subtree up to the next same/higher heading")
    func sectionRange() {
        let text = "# A\nbody a\n## A1\nbody a1\n# B\nbody b"
        let ns = text as NSString
        let nodes = HeadingOutline.parse(text)
        // Section for "# A" runs until "# B".
        let a = nodes[0]
        let bStart = ns.range(of: "# B").location
        #expect(a.sectionRange.location == 0)
        #expect(NSMaxRange(a.sectionRange) == bStart)
        // "## A1" section runs until "# B" too (B is higher level).
        let a1 = nodes[1]
        #expect(NSMaxRange(a1.sectionRange) == bStart)
        // The extracted section text starts with the heading line.
        #expect(ns.substring(with: a1.sectionRange).hasPrefix("## A1"))
    }

    @Test("Last heading's section runs to end of text")
    func lastSectionToEnd() {
        let text = "# A\n## B\ntail"
        let ns = text as NSString
        let nodes = HeadingOutline.parse(text)
        #expect(NSMaxRange(nodes.last!.sectionRange) == ns.length)
    }

    @Test("Headings inside fenced code blocks are ignored")
    func ignoresFencedHeadings() {
        let text = "# Real\n```\n# not a heading\n## also not\n```\n## After"
        let nodes = HeadingOutline.parse(text)
        #expect(nodes.map(\.title) == ["Real", "After"])
    }

    @Test("A run of # without a following space is not a heading")
    func requiresSpace() {
        let text = "#nope\n#### \n# yes"
        let nodes = HeadingOutline.parse(text)
        // "#nope" rejected; "#### " is an empty-title H4; "# yes" is H1.
        #expect(nodes.map(\.title) == ["", "yes"])
        #expect(nodes.map(\.level) == [4, 1])
    }

    @Test("More than six hashes is not a heading")
    func tooManyHashes() {
        #expect(HeadingOutline.parse("####### nope").isEmpty)
    }

    @Test("Heading range excludes the trailing newline")
    func headingRangeExcludesNewline() {
        let text = "# Title\nbody"
        let ns = text as NSString
        let node = HeadingOutline.parse(text)[0]
        #expect(ns.substring(with: node.headingRange) == "# Title")
    }

    @Test("Empty and heading-free documents return no nodes")
    func emptyDocuments() {
        #expect(HeadingOutline.parse("").isEmpty)
        #expect(HeadingOutline.parse("just prose\nno headings").isEmpty)
    }

    @Test("Leading whitespace before # is not an ATX heading")
    func indentedNotHeading() {
        // Indented '#' is a code/text line, not a heading.
        #expect(HeadingOutline.parse("    # indented").isEmpty)
    }
}
