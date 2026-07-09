import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SmartNoteEvaluator")
struct SmartNoteEvaluatorTests {

    // MARK: - Fixtures

    private let calendar = NaturalDateParser.defaultCalendar

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return calendar.date(from: components)!
    }

    /// `now` for the deterministic tests: Tuesday, 2026-07-07, midday UTC.
    private var now: Date { day(2026, 7, 7) }

    private func makeDoc(
        path: String = "note.md",
        content: String,
        tags: [String] = [],
        created: Date? = nil,
        modified: Date? = nil
    ) -> Document {
        Document(
            title: "Note",
            content: content,
            path: path,
            tags: tags,
            created: created ?? day(2026, 7, 1),
            modified: modified ?? day(2026, 7, 1)
        )
    }

    private func matches(_ query: SmartNoteQuery, _ doc: Document) -> SmartNoteMatch? {
        SmartNoteEvaluator.match(query, document: doc, now: now, calendar: calendar)
    }

    // MARK: - Today (mandated rule)

    @Test("Today surfaces headings with scheduled <= today AND status != done")
    func todayPerHeading() {
        let content = """
        ---
        id: 1
        ---

        # Journal

        ## Task A
        > [!props]
        > scheduled:: 2026-07-07
        > status:: todo

        do the thing

        ## Task B
        > [!props]
        > scheduled:: 2026-07-10
        > status:: todo

        ## Task C
        > [!props]
        > scheduled:: 2026-07-06
        > status:: done

        ## Task D
        > [!props]
        > scheduled:: 2026-07-05
        """
        let doc = makeDoc(content: content)
        let match = matches(SmartNoteBuiltins.today.query, doc)
        #expect(match != nil)
        // A: due today, not done → match. D: past-due, no status (counts as not
        // done) → match. B: future. C: done.
        #expect(match?.matchedHeadings.map(\.title) == ["Task A", "Task D"])
        #expect(match?.matchedAtRoot == false)
    }

    @Test("Today matches frontmatter-level scheduling at the document root")
    func todayFrontmatterRoot() {
        let content = """
        ---
        id: 1
        scheduled: 2026-07-07
        status: doing
        ---

        # Note

        body
        """
        let doc = makeDoc(content: content)
        let match = matches(SmartNoteBuiltins.today.query, doc)
        #expect(match?.matchedAtRoot == true)
    }

    @Test("Today excludes a note with nothing scheduled")
    func todayNoSchedule() {
        let doc = makeDoc(content: "# Just a note\n\nno metadata here")
        #expect(matches(SmartNoteBuiltins.today.query, doc) == nil)
    }

    // MARK: - Fields

    @Test("Tag contains / exists / notExists")
    func tagField() {
        let tagged = makeDoc(content: "# T", tags: ["web", "swift"])
        let untagged = makeDoc(content: "# U")
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.tag, .contains, .text("web")))), tagged) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.tag, .contains, .text("web")))), untagged) == nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.tag, .exists, .empty))), tagged) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.tag, .notExists, .empty))), untagged) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.tag, .notExists, .empty))), tagged) == nil)
    }

    @Test("Status equalTo / notEqualTo at frontmatter root")
    func statusField() {
        let content = "---\nid: 1\nstatus: doing\n---\n\n# Note"
        let doc = makeDoc(content: content)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.status, .equalTo, .status(.doing)))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.status, .equalTo, .status(.done)))), doc) == nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.status, .notEqualTo, .status(.done)))), doc) != nil)
    }

    @Test("Absent status counts as not-done for notEqualTo")
    func statusAbsentNotDone() {
        let content = "# Note\n\n## H\n> [!props]\n> scheduled:: 2026-07-07\n"
        let doc = makeDoc(content: content)
        // status != done with no status present → the heading still qualifies.
        let query = SmartNoteQuery(root: .comparison(.init(.status, .notEqualTo, .status(.done))))
        let match = matches(query, doc)
        #expect(match != nil)
    }

    @Test("created within last 7 days (relative date, injected now)")
    func createdRelativeDate() {
        let recent = makeDoc(content: "# R", created: day(2026, 7, 3))     // 4 days ago
        let old = makeDoc(content: "# O", created: day(2026, 6, 20))       // weeks ago
        let query = SmartNoteBuiltins.recentlyCaptured.query
        #expect(matches(query, recent) != nil)
        #expect(matches(query, old) == nil)
    }

    @Test("modified before an absolute date")
    func modifiedAbsoluteDate() {
        let doc = makeDoc(content: "# M", modified: day(2026, 5, 1))
        let cutoff = SmartNoteDate.absolute(day(2026, 6, 1))
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.modified, .lessThan, .date(cutoff)))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.modified, .greaterThan, .date(cutoff)))), doc) == nil)
    }

    @Test("path beginsWith and title contains")
    func pathAndTitle() {
        let doc = Document(title: "Meeting Notes", content: "# x", path: "Web/example.md")
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.path, .beginsWith, .text("Web/")))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.title, .contains, .text("meeting")))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.title, .contains, .text("agenda")))), doc) == nil)
    }

    @Test("full-text contains searches content (case-insensitive)")
    func fullText() {
        let doc = makeDoc(content: "# Physics\n\nNotes on Quantum entanglement.")
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.fullText, .contains, .text("quantum")))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.fullText, .contains, .text("chemistry")))), doc) == nil)
    }

    @Test("frontmatter property equalTo / exists")
    func propertyField() {
        let content = "---\nid: 1\nowner: Mark\n---\n\n# Note"
        let doc = makeDoc(content: content)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.property(key: "owner"), .equalTo, .text("mark")))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.property(key: "owner"), .exists, .empty))), doc) != nil)
        #expect(matches(SmartNoteQuery(root: .comparison(.init(.property(key: "assignee"), .exists, .empty))), doc) == nil)
    }

    // MARK: - Boolean composition

    @Test("AND / OR / NOT nesting")
    func booleanNesting() {
        let doc = makeDoc(content: "# Note", tags: ["swift", "ios"])
        // (tag contains swift AND NOT tag contains rust) OR tag contains python
        let query = SmartNoteQuery(root: .or([
            .and([
                .comparison(.init(.tag, .contains, .text("swift"))),
                .not(.comparison(.init(.tag, .contains, .text("rust"))))
            ]),
            .comparison(.init(.tag, .contains, .text("python")))
        ]))
        #expect(matches(query, doc) != nil)

        let excluded = makeDoc(content: "# Note", tags: ["swift", "rust"])
        #expect(matches(query, excluded) == nil)
    }

    // MARK: - This Week

    @Test("This Week includes an item scheduled the same week, excludes done")
    func thisWeek() {
        // now is Tue 2026-07-07; same-week Wednesday is inside any week start.
        let inWeek = makeDoc(content: "# N\n\n## H\n> [!props]\n> scheduled:: 2026-07-08\n> status:: todo\n")
        let doneItem = makeDoc(content: "# N\n\n## H\n> [!props]\n> scheduled:: 2026-07-08\n> status:: done\n")
        #expect(matches(SmartNoteBuiltins.thisWeek.query, inWeek) != nil)
        #expect(matches(SmartNoteBuiltins.thisWeek.query, doneItem) == nil)
    }

    // MARK: - evaluate() over a set

    @Test("evaluate returns matches in input order")
    func evaluateSet() {
        let a = makeDoc(path: "a.md", content: "# A", tags: ["keep"])
        let b = makeDoc(path: "b.md", content: "# B")
        let c = makeDoc(path: "c.md", content: "# C", tags: ["keep"])
        let query = SmartNoteQuery(root: .comparison(.init(.tag, .contains, .text("keep"))))
        let results = SmartNoteEvaluator.evaluate(query, documents: [a, b, c], now: now, calendar: calendar)
        #expect(results.map(\.document.path) == ["a.md", "c.md"])
    }
}
