import Foundation

/// A saved structured query — the versioned, Codable AST that powers Smart
/// Notes (PUNK-ic6). It is the on-disk source of truth: plain-text, stable, and
/// evaluatable in Core without AppKit. The AppKit `NSPredicateEditor` UI is a
/// pure edge concern — ``SmartNotePredicateBridge`` converts to/from
/// `NSPredicate` only for the rule-builder sheet; nothing evaluates the
/// `NSPredicate` itself.
///
/// A query composes ``SmartNoteComparison`` leaves over the fields a note
/// exposes (tags, status, dates, frontmatter keys, full text) with AND / OR /
/// NOT groups. Per-heading fields (status / scheduled / due) resolve against
/// each heading's `> [!props]` callout as well as the document frontmatter — see
/// ``SmartNoteEvaluator``.
public struct SmartNoteQuery: Codable, Equatable, Sendable {
    /// The newest on-disk schema version this build understands. Bump when the
    /// AST gains a field/operator that older builds could misinterpret; parsers
    /// reject versions above this (see ``fromJSON(_:)`` / ``SmartNoteFile``).
    public static let currentVersion = 1

    public var version: Int
    public var root: SmartNotePredicate

    public init(root: SmartNotePredicate, version: Int = SmartNoteQuery.currentVersion) {
        self.version = version
        self.root = root
    }

    /// Whether any comparison in the tree names a per-heading field
    /// (status / scheduled / due). Drives the evaluator's decision to fan out
    /// over heading scopes rather than only the document root.
    public var usesPerHeadingFields: Bool {
        root.allComparisons.contains { $0.field.isPerHeading }
    }

    // MARK: - JSON (on-disk payload)

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic, single line
        return encoder
    }

    /// Encode to a single-line JSON string for the smart-note file frontmatter.
    public func toJSON() throws -> String {
        let data = try SmartNoteQuery.encoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode from a JSON string, rejecting an unknown/future schema version so
    /// a newer file can't be silently misread by an older build.
    public static func fromJSON(_ string: String) throws -> SmartNoteQuery {
        let query = try JSONDecoder().decode(SmartNoteQuery.self, from: Data(string.utf8))
        guard (1...currentVersion).contains(query.version) else {
            throw SmartNoteQueryError.unsupportedVersion(query.version)
        }
        return query
    }
}

/// Errors decoding a persisted query.
public enum SmartNoteQueryError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

// MARK: - Predicate tree

/// A node in a smart-note query: a comparison leaf, or an AND / OR / NOT group.
public indirect enum SmartNotePredicate: Equatable, Sendable {
    case comparison(SmartNoteComparison)
    case and([SmartNotePredicate])
    case or([SmartNotePredicate])
    case not(SmartNotePredicate)

    /// Every comparison leaf in document order (depth-first).
    public var allComparisons: [SmartNoteComparison] {
        switch self {
        case .comparison(let comparison):
            return [comparison]
        case .and(let children), .or(let children):
            return children.flatMap(\.allComparisons)
        case .not(let child):
            return child.allComparisons
        }
    }
}

extension SmartNotePredicate: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, comparison, children, child
    }

    private enum Kind: String, Codable {
        case comparison, and, or, not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .comparison:
            self = .comparison(try container.decode(SmartNoteComparison.self, forKey: .comparison))
        case .and:
            self = .and(try container.decode([SmartNotePredicate].self, forKey: .children))
        case .or:
            self = .or(try container.decode([SmartNotePredicate].self, forKey: .children))
        case .not:
            self = .not(try container.decode(SmartNotePredicate.self, forKey: .child))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .comparison(let comparison):
            try container.encode(Kind.comparison, forKey: .type)
            try container.encode(comparison, forKey: .comparison)
        case .and(let children):
            try container.encode(Kind.and, forKey: .type)
            try container.encode(children, forKey: .children)
        case .or(let children):
            try container.encode(Kind.or, forKey: .type)
            try container.encode(children, forKey: .children)
        case .not(let child):
            try container.encode(Kind.not, forKey: .type)
            try container.encode(child, forKey: .child)
        }
    }
}

/// One comparison leaf: `field op value`, e.g. `scheduled <= today`.
public struct SmartNoteComparison: Codable, Equatable, Sendable {
    public var field: SmartNoteField
    public var op: SmartNoteOperator
    public var value: SmartNoteValue

    public init(_ field: SmartNoteField, _ op: SmartNoteOperator, _ value: SmartNoteValue) {
        self.field = field
        self.op = op
        self.value = value
    }
}

// MARK: - Fields

/// A queryable attribute of a note. Most are document-level; `status`,
/// `scheduled`, and `due` are per-heading (they also read from frontmatter).
public enum SmartNoteField: Equatable, Sendable, Hashable {
    case tag
    case status
    case scheduled
    case due
    case created
    case modified
    case fullText
    case path
    case title
    /// An arbitrary frontmatter (or heading-callout custom) key.
    case property(key: String)

    /// Whether this field resolves against a heading's props callout rather than
    /// the document as a whole.
    public var isPerHeading: Bool {
        switch self {
        case .status, .scheduled, .due: return true
        default: return false
        }
    }

    /// Whether this field carries a date value (drives value interpretation in
    /// the bridge and evaluator).
    public var isDate: Bool {
        switch self {
        case .scheduled, .due, .created, .modified: return true
        default: return false
        }
    }

    /// Stable single-token spelling used for the on-disk JSON.
    public var token: String {
        switch self {
        case .tag: return "tag"
        case .status: return "status"
        case .scheduled: return "scheduled"
        case .due: return "due"
        case .created: return "created"
        case .modified: return "modified"
        case .fullText: return "fullText"
        case .path: return "path"
        case .title: return "title"
        case .property(let key): return "property:\(key)"
        }
    }

    /// Parse a `token` back into a field, or `nil` if unrecognized.
    public static func parse(token: String) -> SmartNoteField? {
        let propertyPrefix = "property:"
        if token.hasPrefix(propertyPrefix) {
            return .property(key: String(token.dropFirst(propertyPrefix.count)))
        }
        switch token {
        case "tag": return .tag
        case "status": return .status
        case "scheduled": return .scheduled
        case "due": return .due
        case "created": return .created
        case "modified": return .modified
        case "fullText": return .fullText
        case "path": return .path
        case "title": return .title
        default: return nil
        }
    }

    /// Human label for descriptions/UI.
    public var displayName: String {
        switch self {
        case .tag: return "tag"
        case .status: return "status"
        case .scheduled: return "scheduled"
        case .due: return "due"
        case .created: return "created"
        case .modified: return "modified"
        case .fullText: return "text"
        case .path: return "path"
        case .title: return "title"
        case .property(let key): return key
        }
    }
}

extension SmartNoteField: Codable {
    public init(from decoder: Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        guard let field = SmartNoteField.parse(token: token) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown field token: \(token)")
            )
        }
        self = field
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

// MARK: - Operators

/// The comparison operators smart notes support. All map 1:1 onto
/// `NSComparisonPredicate.Operator` (existence uses an `NSNull` sentinel — see
/// ``SmartNotePredicateBridge``), so the bridge round-trips losslessly.
public enum SmartNoteOperator: String, Codable, Equatable, Sendable, CaseIterable {
    case equalTo
    case notEqualTo
    case lessThan
    case lessThanOrEqualTo
    case greaterThan
    case greaterThanOrEqualTo
    case contains
    case beginsWith
    case exists
    case notExists

    /// Human label for descriptions/UI.
    public var displayName: String {
        switch self {
        case .equalTo: return "is"
        case .notEqualTo: return "is not"
        case .lessThan: return "is before"
        case .lessThanOrEqualTo: return "is on or before"
        case .greaterThan: return "is after"
        case .greaterThanOrEqualTo: return "is on or after"
        case .contains: return "contains"
        case .beginsWith: return "begins with"
        case .exists: return "is set"
        case .notExists: return "is empty"
        }
    }

    /// Existence operators ignore their value.
    public var isExistence: Bool { self == .exists || self == .notExists }
}

// MARK: - Values

/// The right-hand side of a comparison. The `field` determines which case is
/// meaningful; existence operators use ``empty``.
public enum SmartNoteValue: Equatable, Sendable {
    case text(String)
    case status(PropsStatus)
    case date(SmartNoteDate)
    /// Placeholder for existence operators (`is set` / `is empty`).
    case empty

    /// Human label for descriptions/UI.
    public var displayName: String {
        switch self {
        case .text(let string): return "“\(string)”"
        case .status(let status): return status.rawValue
        case .date(let date): return date.displayName
        case .empty: return ""
        }
    }
}

extension SmartNoteValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, status, date
    }

    private enum Kind: String, Codable {
        case text, status, date, empty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .status:
            let raw = try container.decode(String.self, forKey: .status)
            guard let status = PropsStatus(rawValue: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown status: \(raw)")
                )
            }
            self = .status(status)
        case .date:
            self = .date(try container.decode(SmartNoteDate.self, forKey: .date))
        case .empty:
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let string):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(string, forKey: .text)
        case .status(let status):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(status.rawValue, forKey: .status)
        case .date(let date):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .empty:
            try container.encode(Kind.empty, forKey: .kind)
        }
    }
}

/// A date operand: either an absolute instant or a relative anchor resolved
/// against an injected `now` at evaluation time (never baked in on disk, so
/// "today" stays "today" across launches).
public enum SmartNoteDate: Equatable, Sendable {
    case today
    case startOfWeek
    case endOfWeek
    /// `today ± n` days (negative = past). `daysFromToday(-7)` = a week ago.
    case daysFromToday(Int)
    case absolute(Date)

    /// The start-of-day the anchor resolves to under `calendar`, relative to
    /// `now`. Date comparisons work at day granularity so a scheduled item with
    /// a time-of-day still counts as "today".
    public func resolvedDay(now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return startOfToday
        case .daysFromToday(let offset):
            return calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
        case .startOfWeek:
            return SmartNoteDate.startOfWeek(for: now, calendar: calendar)
        case .endOfWeek:
            let start = SmartNoteDate.startOfWeek(for: now, calendar: calendar)
            return calendar.date(byAdding: .day, value: 6, to: start) ?? start
        case .absolute(let date):
            return calendar.startOfDay(for: date)
        }
    }

    /// First day of the calendar week containing `now`, honoring `firstWeekday`.
    private static func startOfWeek(for now: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? calendar.startOfDay(for: now)
    }

    /// Human label for descriptions/UI.
    public var displayName: String {
        switch self {
        case .today: return "today"
        case .startOfWeek: return "start of week"
        case .endOfWeek: return "end of week"
        case .daysFromToday(let offset):
            if offset == 0 { return "today" }
            let magnitude = abs(offset)
            let unit = magnitude == 1 ? "day" : "days"
            return offset < 0 ? "\(magnitude) \(unit) ago" : "in \(magnitude) \(unit)"
        case .absolute(let date):
            return SmartNoteDate.isoFormatter.string(from: date)
        }
    }

    /// Whole-day ISO formatter for on-disk absolute dates. A fresh instance per
    /// access keeps it `Sendable`-clean (`ISO8601DateFormatter` isn't Sendable).
    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

extension SmartNoteDate: Codable {
    private enum CodingKeys: String, CodingKey {
        case anchor, days, date
    }

    private enum Anchor: String, Codable {
        case today, startOfWeek, endOfWeek, daysFromToday, absolute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Anchor.self, forKey: .anchor) {
        case .today:
            self = .today
        case .startOfWeek:
            self = .startOfWeek
        case .endOfWeek:
            self = .endOfWeek
        case .daysFromToday:
            self = .daysFromToday(try container.decode(Int.self, forKey: .days))
        case .absolute:
            let raw = try container.decode(String.self, forKey: .date)
            guard let date = SmartNoteDate.isoFormatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad ISO date: \(raw)")
                )
            }
            self = .absolute(date)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .today:
            try container.encode(Anchor.today, forKey: .anchor)
        case .startOfWeek:
            try container.encode(Anchor.startOfWeek, forKey: .anchor)
        case .endOfWeek:
            try container.encode(Anchor.endOfWeek, forKey: .anchor)
        case .daysFromToday(let offset):
            try container.encode(Anchor.daysFromToday, forKey: .anchor)
            try container.encode(offset, forKey: .days)
        case .absolute(let date):
            try container.encode(Anchor.absolute, forKey: .anchor)
            try container.encode(SmartNoteDate.isoFormatter.string(from: date), forKey: .date)
        }
    }
}
