import Foundation

/// A built-in smart note: a code-defined query shown above the user's saved
/// smart notes. Built-ins are never written to disk — they always reflect the
/// current definition here.
public struct SmartNoteBuiltin: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let systemImage: String
    public let query: SmartNoteQuery

    public init(id: String, name: String, systemImage: String, query: SmartNoteQuery) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.query = query
    }
}

/// The shipped built-in smart notes (PUNK-ic6).
///
/// Definitions (documented so the on-screen list is predictable):
/// - **Inbox** — unfiled captures: untagged notes that sit at the vault root
///   (their path contains no `/`). The classic "process me" pile.
/// - **Today** — the mandated rule: a heading whose `scheduled` date is on or
///   before today **and** whose status is not `done` (absent status counts as
///   not done). Frontmatter-level scheduling counts too.
/// - **This Week** — a heading `scheduled` within the current calendar week
///   (start-of-week … end-of-week, inclusive) and not `done`.
/// - **Untagged** — notes with no tags at all.
/// - **Recently Captured** — notes `created` within the last 7 days.
/// - **Web Summaries** — notes under the `Web/` folder, or tagged `web`
///   (the web-summary feature writes into the `Web/` tree).
public enum SmartNoteBuiltins {

    public static let all: [SmartNoteBuiltin] = [
        inbox, today, thisWeek, untagged, recentlyCaptured, webSummaries
    ]

    public static let inbox = SmartNoteBuiltin(
        id: "builtin.inbox",
        name: "Inbox",
        systemImage: "tray",
        query: SmartNoteQuery(root: .and([
            .comparison(SmartNoteComparison(.tag, .notExists, .empty)),
            .not(.comparison(SmartNoteComparison(.path, .contains, .text("/"))))
        ]))
    )

    public static let today = SmartNoteBuiltin(
        id: "builtin.today",
        name: "Today",
        systemImage: "sun.max",
        query: SmartNoteQuery(root: .and([
            .comparison(SmartNoteComparison(.scheduled, .lessThanOrEqualTo, .date(.today))),
            .comparison(SmartNoteComparison(.status, .notEqualTo, .status(.done)))
        ]))
    )

    public static let thisWeek = SmartNoteBuiltin(
        id: "builtin.thisWeek",
        name: "This Week",
        systemImage: "calendar",
        query: SmartNoteQuery(root: .and([
            .comparison(SmartNoteComparison(.scheduled, .greaterThanOrEqualTo, .date(.startOfWeek))),
            .comparison(SmartNoteComparison(.scheduled, .lessThanOrEqualTo, .date(.endOfWeek))),
            .comparison(SmartNoteComparison(.status, .notEqualTo, .status(.done)))
        ]))
    )

    public static let untagged = SmartNoteBuiltin(
        id: "builtin.untagged",
        name: "Untagged",
        systemImage: "tag.slash",
        query: SmartNoteQuery(root: .comparison(SmartNoteComparison(.tag, .notExists, .empty)))
    )

    public static let recentlyCaptured = SmartNoteBuiltin(
        id: "builtin.recentlyCaptured",
        name: "Recently Captured",
        systemImage: "clock.arrow.circlepath",
        query: SmartNoteQuery(root: .comparison(
            SmartNoteComparison(.created, .greaterThanOrEqualTo, .date(.daysFromToday(-7)))
        ))
    )

    public static let webSummaries = SmartNoteBuiltin(
        id: "builtin.webSummaries",
        name: "Web Summaries",
        systemImage: "globe",
        query: SmartNoteQuery(root: .or([
            .comparison(SmartNoteComparison(.path, .beginsWith, .text("Web/"))),
            .comparison(SmartNoteComparison(.tag, .contains, .text("web")))
        ]))
    )
}
