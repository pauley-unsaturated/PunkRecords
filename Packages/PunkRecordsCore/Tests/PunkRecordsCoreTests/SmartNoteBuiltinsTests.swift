import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SmartNoteBuiltins")
struct SmartNoteBuiltinsTests {

    private let calendar = NaturalDateParser.defaultCalendar

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return calendar.date(from: components)!
    }

    private var now: Date { day(2026, 7, 7) }

    private func matches(_ query: SmartNoteQuery, _ doc: Document) -> Bool {
        SmartNoteEvaluator.match(query, document: doc, now: now, calendar: calendar) != nil
    }

    @Test("There are six built-ins with unique ids")
    func builtinRoster() {
        let ids = SmartNoteBuiltins.all.map(\.id)
        #expect(ids.count == 6)
        #expect(Set(ids).count == 6)
        #expect(SmartNoteBuiltins.all.map(\.name) ==
                ["Inbox", "Today", "This Week", "Untagged", "Recently Captured", "Web Summaries"])
    }

    @Test("Inbox: untagged note at the vault root")
    func inbox() {
        let unfiled = Document(title: "Capture", content: "# c", path: "quick capture.md")
        let filed = Document(title: "Filed", content: "# c", path: "Projects/note.md")
        let tagged = Document(title: "Tagged", content: "# c", path: "root.md", tags: ["idea"])
        #expect(matches(SmartNoteBuiltins.inbox.query, unfiled))
        #expect(matches(SmartNoteBuiltins.inbox.query, filed) == false)   // in a folder
        #expect(matches(SmartNoteBuiltins.inbox.query, tagged) == false)  // has a tag
    }

    @Test("Today: a scheduled, not-done heading")
    func today() {
        let doc = Document(
            title: "T",
            content: "# T\n\n## Task\n> [!props]\n> scheduled:: 2026-07-07\n> status:: todo\n",
            path: "t.md"
        )
        #expect(matches(SmartNoteBuiltins.today.query, doc))
    }

    @Test("This Week: a heading scheduled inside the current week")
    func thisWeek() {
        let doc = Document(
            title: "W",
            content: "# W\n\n## Task\n> [!props]\n> scheduled:: 2026-07-08\n> status:: todo\n",
            path: "w.md"
        )
        #expect(matches(SmartNoteBuiltins.thisWeek.query, doc))
    }

    @Test("Untagged: a note with no tags")
    func untagged() {
        let bare = Document(title: "B", content: "# b", path: "b.md")
        let tagged = Document(title: "T", content: "# t", path: "t.md", tags: ["x"])
        #expect(matches(SmartNoteBuiltins.untagged.query, bare))
        #expect(matches(SmartNoteBuiltins.untagged.query, tagged) == false)
    }

    @Test("Recently Captured: created within the last week")
    func recentlyCaptured() {
        let fresh = Document(title: "F", content: "# f", path: "f.md", created: day(2026, 7, 5))
        let stale = Document(title: "S", content: "# s", path: "s.md", created: day(2026, 5, 1))
        #expect(matches(SmartNoteBuiltins.recentlyCaptured.query, fresh))
        #expect(matches(SmartNoteBuiltins.recentlyCaptured.query, stale) == false)
    }

    @Test("Web Summaries: matches Web/ path or web tag")
    func webSummaries() {
        let byPath = Document(title: "P", content: "# p", path: "Web/example-com.md")
        let byTag = Document(title: "G", content: "# g", path: "notes/g.md", tags: ["web"])
        let neither = Document(title: "N", content: "# n", path: "notes/n.md", tags: ["idea"])
        #expect(matches(SmartNoteBuiltins.webSummaries.query, byPath))
        #expect(matches(SmartNoteBuiltins.webSummaries.query, byTag))
        #expect(matches(SmartNoteBuiltins.webSummaries.query, neither) == false)
    }
}
