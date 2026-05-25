import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("HeadingRefile Tests")
struct HeadingRefileTests {
    /// Locate a heading's section range by title via the outline parser.
    private func section(_ title: String, in text: String) -> NSRange {
        HeadingOutline.parse(text).first { $0.title == title }!.sectionRange
    }

    @Test("extract lifts the section and leaves tidy source")
    func extractLifts() {
        let source = "# Keep\nintro\n\n## Move me\ncontent\n\n# After\ntail"
        let range = section("Move me", in: source)
        let result = HeadingRefile.extract(from: source, sectionRange: range)
        #expect(result?.section == "## Move me\ncontent\n")
        #expect(result?.remainingSource == "# Keep\nintro\n\n# After\ntail")
    }

    @Test("extract returns nil for an invalid range")
    func extractInvalid() {
        #expect(HeadingRefile.extract(from: "# A", sectionRange: NSRange(location: 0, length: 0)) == nil)
        #expect(HeadingRefile.extract(from: "# A", sectionRange: NSRange(location: 0, length: 999)) == nil)
    }

    @Test("extract collapses the blank-line seam left behind")
    func extractCollapsesSeam() {
        // Removing the middle section must not leave three blank lines.
        let source = "# A\n\n## Mid\nx\n\n## B\ny"
        let range = section("Mid", in: source)
        let result = HeadingRefile.extract(from: source, sectionRange: range)
        #expect(result?.remainingSource.contains("\n\n\n") == false)
        #expect(result?.section == "## Mid\nx\n")
    }

    @Test("insert at end of document adds a blank-line separator")
    func insertAtEnd() {
        let target = "# Doc\nstuff"
        let out = HeadingRefile.insert("## X\nbody\n", into: target, at: (target as NSString).length)
        #expect(out == "# Doc\nstuff\n\n## X\nbody\n")
    }

    @Test("insert into empty target yields just the section")
    func insertIntoEmpty() {
        let out = HeadingRefile.insert("## X\nbody\n", into: "", at: 0)
        #expect(out == "## X\nbody\n")
    }

    @Test("append targets the end of the document when no parent section")
    func appendAtDocEnd() {
        let target = "# One\na"
        let out = HeadingRefile.append("## Two\nb\n", into: target, endingAt: nil)
        #expect(out == "# One\na\n\n## Two\nb\n")
    }

    @Test("round-trip: move a subtree from source into target under a heading")
    func roundTripMove() {
        let source = "# Src\nintro\n\n## Topic\nbody1\nbody2\n\n## Other\nx"
        let target = "# Dest\n\n## Bucket\nexisting\n\n## Tail\nz"

        let topic = section("Topic", in: source)
        let extraction = HeadingRefile.extract(from: source, sectionRange: topic)!
        // Append under "Bucket" — i.e. at the end of Bucket's section.
        let bucketEnd = NSMaxRange(section("Bucket", in: target))
        let newTarget = HeadingRefile.append(extraction.section, into: target, endingAt: bucketEnd)

        // Source no longer has Topic; target now does, and Tail is intact.
        #expect(!extraction.remainingSource.contains("## Topic"))
        #expect(extraction.remainingSource.contains("## Other"))
        #expect(newTarget.contains("## Topic\nbody1\nbody2"))
        #expect(newTarget.contains("## Tail\nz"))
        // The moved section sits before Tail (appended at end of Bucket).
        let topicIdx = (newTarget as NSString).range(of: "## Topic").location
        let tailIdx = (newTarget as NSString).range(of: "## Tail").location
        #expect(topicIdx < tailIdx)
    }
}
