import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("HeadingRefileLinks Tests")
struct HeadingRefileLinksTests {
    private func rewrite(
        _ notes: [(title: String, content: String)],
        heading: String,
        from source: String,
        to dest: String
    ) -> [HeadingRefileLinks.NoteRewrite] {
        HeadingRefileLinks.rewriteHeadingLinks(in: notes, movingHeading: heading, fromNote: source, toNote: dest)
    }

    @Test("Rewrites a matching heading link to the destination note")
    func rewritesMatch() {
        let notes = [(title: "Other", content: "see [[Source#Topic]] here")]
        let out = rewrite(notes, heading: "Topic", from: "Source", to: "Dest")
        #expect(out.count == 1)
        #expect(out[0].title == "Other")
        #expect(out[0].count == 1)
        #expect(out[0].newContent == "see [[Dest#Topic]] here")
    }

    @Test("Preserves the alias when rewriting")
    func preservesAlias() {
        let notes = [(title: "N", content: "[[Source#Topic|the topic]]")]
        let out = rewrite(notes, heading: "Topic", from: "Source", to: "Dest")
        #expect(out[0].newContent == "[[Dest#Topic|the topic]]")
    }

    @Test("Matching is case-insensitive on note and heading")
    func caseInsensitive() {
        let notes = [(title: "N", content: "[[source#TOPIC]]")]
        let out = rewrite(notes, heading: "topic", from: "SOURCE", to: "Dest")
        #expect(out.count == 1)
        #expect(out[0].newContent == "[[Dest#TOPIC]]")
    }

    @Test("Leaves non-matching links untouched")
    func leavesOthers() {
        let notes = [(title: "N", content: "[[Source#Other]] and [[Elsewhere#Topic]] and [[Source]]")]
        let out = rewrite(notes, heading: "Topic", from: "Source", to: "Dest")
        #expect(out.isEmpty, "no link targets Source#Topic exactly")
    }

    @Test("Counts and rewrites multiple links across notes")
    func multipleNotes() {
        let notes = [
            (title: "A", content: "[[Source#Topic]] x [[Source#Topic|t]]"),
            (title: "B", content: "no links"),
            (title: "C", content: "[[Source#Topic]]"),
        ]
        let out = rewrite(notes, heading: "Topic", from: "Source", to: "Dest")
        #expect(out.map(\.title) == ["A", "C"])
        #expect(out.first { $0.title == "A" }?.count == 2)
        #expect(out.first { $0.title == "C" }?.count == 1)
    }

    @Test("No-ops when source and destination are the same note")
    func sameNoteNoOp() {
        let notes = [(title: "N", content: "[[Source#Topic]]")]
        #expect(rewrite(notes, heading: "Topic", from: "Source", to: "Source").isEmpty)
    }

    @Test("Plain note links without an anchor are never matched")
    func plainNoteLinkIgnored() {
        let notes = [(title: "N", content: "[[Source]] and [[Source#]]")]
        let out = rewrite(notes, heading: "Topic", from: "Source", to: "Dest")
        #expect(out.isEmpty)
    }
}
