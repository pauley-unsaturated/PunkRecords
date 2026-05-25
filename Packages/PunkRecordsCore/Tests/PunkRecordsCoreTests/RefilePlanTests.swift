import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("RefilePlan Tests")
struct RefilePlanTests {
    private func section(_ title: String, in content: String) -> NSRange {
        HeadingOutline.parse(content).first { $0.title == title }!.sectionRange
    }

    private func request(
        source: String, section: NSRange, heading: String,
        dest: String, target: [String]?, updateLinks: Bool
    ) -> RefilePlan.Request {
        RefilePlan.Request(
            sourcePath: source, sectionRange: section, headingTitle: heading,
            destPath: dest, targetHeadingPath: target, updateLinks: updateLinks
        )
    }

    @Test("Cross-note move rewrites source and destination")
    func crossNote() {
        let source = RefilePlan.Note(path: "a.md", title: "A", content: "# A\nintro\n\n## Move\nbody\n\n## Stay\nx")
        let dest = RefilePlan.Note(path: "b.md", title: "B", content: "# B\n\n## Bucket\nexisting")
        let changes = RefilePlan.make(notes: [source, dest], request(
            source: "a.md", section: section("Move", in: source.content), heading: "Move",
            dest: "b.md", target: ["B", "Bucket"], updateLinks: false
        ))
        #expect(changes != nil)
        let byPath = Dictionary(uniqueKeysWithValues: changes!.map { ($0.path, $0.newContent) })
        #expect(byPath["a.md"]?.contains("## Move") == false)
        #expect(byPath["a.md"]?.contains("## Stay") == true)
        #expect(byPath["b.md"]?.contains("## Move\nbody") == true)
        #expect(byPath["b.md"]?.contains("## Bucket") == true)
    }

    @Test("Append at end of destination when no target heading")
    func appendAtEnd() {
        let source = RefilePlan.Note(path: "a.md", title: "A", content: "## Move\nbody\n")
        let dest = RefilePlan.Note(path: "b.md", title: "B", content: "# B\ntail")
        let changes = RefilePlan.make(notes: [source, dest], request(
            source: "a.md", section: section("Move", in: source.content), heading: "Move",
            dest: "b.md", target: nil, updateLinks: false
        ))
        let byPath = Dictionary(uniqueKeysWithValues: (changes ?? []).map { ($0.path, $0.newContent) })
        #expect(byPath["b.md"]?.hasSuffix("## Move\nbody\n") == true)
    }

    @Test("Same-note reorder produces a single change")
    func sameNote() {
        let content = "# Doc\n\n## First\na\n\n## Second\nb"
        let note = RefilePlan.Note(path: "d.md", title: "Doc", content: content)
        let changes = RefilePlan.make(notes: [note], request(
            source: "d.md", section: section("First", in: content), heading: "First",
            dest: "d.md", target: nil, updateLinks: false
        ))
        #expect(changes?.count == 1)
        let new = changes![0].newContent
        let firstIdx = (new as NSString).range(of: "## First").location
        let secondIdx = (new as NSString).range(of: "## Second").location
        #expect(secondIdx < firstIdx)
    }

    @Test("updateLinks rewrites references to the moved heading")
    func withLinkUpdate() {
        let source = RefilePlan.Note(path: "a.md", title: "A", content: "## Topic\nbody")
        let dest = RefilePlan.Note(path: "b.md", title: "B", content: "# B")
        let other = RefilePlan.Note(path: "c.md", title: "C", content: "see [[A#Topic]]")
        let changes = RefilePlan.make(notes: [source, dest, other], request(
            source: "a.md", section: section("Topic", in: source.content), heading: "Topic",
            dest: "b.md", target: nil, updateLinks: true
        ))
        let byPath = Dictionary(uniqueKeysWithValues: (changes ?? []).map { ($0.path, $0.newContent) })
        #expect(byPath["c.md"]?.contains("[[B#Topic]]") == true)
    }

    @Test("Skipping link update leaves references untouched")
    func withoutLinkUpdate() {
        let source = RefilePlan.Note(path: "a.md", title: "A", content: "## Topic\nbody")
        let dest = RefilePlan.Note(path: "b.md", title: "B", content: "# B")
        let other = RefilePlan.Note(path: "c.md", title: "C", content: "see [[A#Topic]]")
        let changes = RefilePlan.make(notes: [source, dest, other], request(
            source: "a.md", section: section("Topic", in: source.content), heading: "Topic",
            dest: "b.md", target: nil, updateLinks: false
        ))
        let paths = Set((changes ?? []).map(\.path))
        #expect(!paths.contains("c.md"), "c.md unchanged when links aren't updated")
    }

    @Test("Invalid inputs return nil")
    func invalid() {
        let note = RefilePlan.Note(path: "a.md", title: "A", content: "## X\nbody")
        #expect(RefilePlan.make(notes: [note], request(
            source: "a.md", section: section("X", in: note.content), heading: "X",
            dest: "missing.md", target: nil, updateLinks: false
        )) == nil)
        #expect(RefilePlan.make(notes: [note], request(
            source: "a.md", section: NSRange(location: 0, length: 0), heading: "X",
            dest: "a.md", target: nil, updateLinks: false
        )) == nil)
    }
}
