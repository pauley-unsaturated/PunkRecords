import Foundation

/// One document that satisfied a ``SmartNoteQuery``, plus which scopes matched.
///
/// - `matchedAtRoot` is true when the document's frontmatter (or a doc-level
///   field like `tag`/`created`) satisfied the query.
/// - `matchedHeadings` lists the headings whose `> [!props]` callouts satisfied
///   a per-heading query (e.g. the scheduled headings a "Today" query surfaces).
public struct SmartNoteMatch: Equatable, Sendable {
    public let document: Document
    public let matchedAtRoot: Bool
    public let matchedHeadings: [HeadingNode]

    public init(document: Document, matchedAtRoot: Bool, matchedHeadings: [HeadingNode]) {
        self.document = document
        self.matchedAtRoot = matchedAtRoot
        self.matchedHeadings = matchedHeadings
    }
}

/// Evaluates a ``SmartNoteQuery`` against documents — the pure, unit-tested core
/// of Smart Notes (PUNK-ic6). No AppKit, no search index: full-text is a simple
/// content `contains` (a search-index fast path is a later optimization).
///
/// ## Scopes
/// A document is checked against a set of *scopes*: its frontmatter root plus,
/// for queries that name a per-heading field (status / scheduled / due), each
/// heading. Document-level fields (tag, dates, path, title, text, frontmatter
/// keys) resolve the same in every scope; per-heading fields read that scope's
/// props. The document matches if any scope satisfies the predicate.
///
/// ## Dates
/// Comparisons resolve relative anchors (`today`, `startOfWeek`, …) against an
/// injected `now`, and compare at **day** granularity, so `scheduled <= today`
/// includes an item scheduled for later *today*.
public enum SmartNoteEvaluator {

    /// Evaluate `query` over `documents`, returning a match per surviving doc in
    /// input order.
    public static func evaluate(
        _ query: SmartNoteQuery,
        documents: [Document],
        now: Date = Date(),
        calendar: Calendar = NaturalDateParser.defaultCalendar
    ) -> [SmartNoteMatch] {
        documents.compactMap { match(query, document: $0, now: now, calendar: calendar) }
    }

    /// Evaluate `query` against a single document, or `nil` if it doesn't match.
    public static func match(
        _ query: SmartNoteQuery,
        document: Document,
        now: Date = Date(),
        calendar: Calendar = NaturalDateParser.defaultCalendar
    ) -> SmartNoteMatch? {
        let content = document.content
        let rootProps = HeadingProps.readFrontmatter(from: content)
        let rootScope = Scope(document: document, props: rootProps, heading: nil)
        let matchedAtRoot = evaluate(query.root, in: rootScope, now: now, calendar: calendar)

        var matchedHeadings: [HeadingNode] = []
        if query.usesPerHeadingFields {
            for heading in HeadingOutline.parse(content) {
                let props = HeadingProps.read(from: content, heading: heading)
                let scope = Scope(document: document, props: props, heading: heading)
                if evaluate(query.root, in: scope, now: now, calendar: calendar) {
                    matchedHeadings.append(heading)
                }
            }
        }

        guard matchedAtRoot || !matchedHeadings.isEmpty else { return nil }
        return SmartNoteMatch(document: document, matchedAtRoot: matchedAtRoot, matchedHeadings: matchedHeadings)
    }

    // MARK: - Scope

    /// One evaluatable unit: the whole document plus the props of a particular
    /// heading (or the frontmatter root when `heading == nil`).
    private struct Scope {
        let document: Document
        let props: PropsBlock
        let heading: HeadingNode?
    }

    // MARK: - Predicate walk

    private static func evaluate(_ predicate: SmartNotePredicate, in scope: Scope, now: Date, calendar: Calendar) -> Bool {
        switch predicate {
        case .comparison(let comparison):
            return evaluate(comparison, in: scope, now: now, calendar: calendar)
        case .and(let children):
            return children.allSatisfy { evaluate($0, in: scope, now: now, calendar: calendar) }
        case .or(let children):
            return children.contains { evaluate($0, in: scope, now: now, calendar: calendar) }
        case .not(let child):
            return !evaluate(child, in: scope, now: now, calendar: calendar)
        }
    }

    private static func evaluate(_ comparison: SmartNoteComparison, in scope: Scope, now: Date, calendar: Calendar) -> Bool {
        switch comparison.field {
        case .tag:
            return evaluateTag(comparison, in: scope)
        case .status:
            return evaluateStatus(comparison, status: scope.props.status)
        case .scheduled:
            return evaluateDate(comparison, raw: scope.props.scheduled, now: now, calendar: calendar)
        case .due:
            return evaluateDate(comparison, raw: scope.props.due, now: now, calendar: calendar)
        case .created:
            return evaluateDate(comparison, date: scope.document.created, now: now, calendar: calendar)
        case .modified:
            return evaluateDate(comparison, date: scope.document.modified, now: now, calendar: calendar)
        case .fullText:
            let haystack = scope.document.title + "\n" + scope.document.content
            return evaluateString(comparison, current: haystack)
        case .path:
            return evaluateString(comparison, current: scope.document.path)
        case .title:
            return evaluateString(comparison, current: scope.document.title)
        case .property(let key):
            return evaluateString(comparison, current: propertyValue(key, in: scope))
        }
    }

    // MARK: - Tags (set membership)

    private static func evaluateTag(_ comparison: SmartNoteComparison, in scope: Scope) -> Bool {
        let tags = Set(scope.document.tags + scope.props.tags)   // both already lowercased
        switch comparison.op {
        case .exists:
            return !tags.isEmpty
        case .notExists:
            return tags.isEmpty
        case .equalTo:
            return tags.contains(needle(comparison.value))
        case .notEqualTo:
            return !tags.contains(needle(comparison.value))
        case .contains:
            return tags.contains(needle(comparison.value))
        case .beginsWith:
            let prefix = needle(comparison.value)
            return tags.contains { $0.hasPrefix(prefix) }
        case .lessThan, .lessThanOrEqualTo, .greaterThan, .greaterThanOrEqualTo:
            return false
        }
    }

    // MARK: - Status (enum)

    private static func evaluateStatus(_ comparison: SmartNoteComparison, status: PropsStatus?) -> Bool {
        switch comparison.op {
        case .exists:
            return status != nil
        case .notExists:
            return status == nil
        case .equalTo:
            return status == expectedStatus(comparison.value)
        case .notEqualTo:
            // Absent status counts as "not done" etc. — matches the Today rule.
            return status != expectedStatus(comparison.value)
        default:
            return false
        }
    }

    // MARK: - Dates (day granularity)

    private static func evaluateDate(_ comparison: SmartNoteComparison, raw: String?, now: Date, calendar: Calendar) -> Bool {
        let parsed = raw.flatMap { parsePropDate($0, now: now, calendar: calendar) }
        return evaluateDate(comparison, date: parsed, now: now, calendar: calendar)
    }

    private static func evaluateDate(_ comparison: SmartNoteComparison, date: Date?, now: Date, calendar: Calendar) -> Bool {
        switch comparison.op {
        case .exists:
            return date != nil
        case .notExists:
            return date == nil
        default:
            break
        }
        guard case .date(let anchor) = comparison.value else {
            // Non-date operand on a date field: only existence is meaningful.
            return false
        }
        let target = anchor.resolvedDay(now: now, calendar: calendar)
        guard let date else {
            // Absent date: "not equal" is vacuously true, orderings are false.
            return comparison.op == .notEqualTo
        }
        let day = calendar.startOfDay(for: date)
        switch comparison.op {
        case .equalTo: return day == target
        case .notEqualTo: return day != target
        case .lessThan: return day < target
        case .lessThanOrEqualTo: return day <= target
        case .greaterThan: return day > target
        case .greaterThanOrEqualTo: return day >= target
        case .contains, .beginsWith, .exists, .notExists: return false
        }
    }

    // MARK: - Strings

    private static func evaluateString(_ comparison: SmartNoteComparison, current: String?) -> Bool {
        switch comparison.op {
        case .exists:
            return !(current ?? "").isEmpty
        case .notExists:
            return (current ?? "").isEmpty
        default:
            break
        }
        let haystack = (current ?? "").lowercased()
        let value = needle(comparison.value)
        switch comparison.op {
        case .equalTo: return haystack == value
        case .notEqualTo: return haystack != value
        case .contains: return haystack.contains(value)
        case .beginsWith: return haystack.hasPrefix(value)
        case .lessThan, .lessThanOrEqualTo, .greaterThan, .greaterThanOrEqualTo, .exists, .notExists:
            return false
        }
    }

    // MARK: - Helpers

    /// The comparison's text operand, lowercased for case-insensitive matching.
    private static func needle(_ value: SmartNoteValue) -> String {
        switch value {
        case .text(let string): return string.lowercased()
        case .status(let status): return status.rawValue.lowercased()
        case .date(let date): return date.displayName.lowercased()
        case .empty: return ""
        }
    }

    private static func expectedStatus(_ value: SmartNoteValue) -> PropsStatus? {
        switch value {
        case .status(let status): return status
        case .text(let raw): return PropsStatus(rawValue: raw.lowercased())
        default: return nil
        }
    }

    /// Case-insensitive frontmatter / heading-callout custom-field lookup.
    private static func propertyValue(_ key: String, in scope: Scope) -> String? {
        let lowered = key.lowercased()
        if let field = scope.props.custom.first(where: { $0.key.lowercased() == lowered }) {
            return field.value
        }
        if let exact = scope.document.frontmatter[key] {
            return exact
        }
        return scope.document.frontmatter.first { $0.key.lowercased() == lowered }?.value
    }

    /// Parse a stored props date string (canonical `yyyy-MM-dd[ HH:mm]`, or any
    /// natural-language value the inspector left verbatim) into a `Date`.
    static func parsePropDate(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return NaturalDateParser.parse(trimmed, now: now, calendar: calendar)?.date
    }
}
