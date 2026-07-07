import Foundation

/// The three hard-coded task states. Custom per-file state sets are a
/// deliberate scope cut (PUNK-4bz / the org-mode translation guide): three
/// states, no user configuration.
public enum PropsStatus: String, CaseIterable, Sendable, Equatable {
    case todo
    case doing
    case done

    /// A human-facing label for the inspector's status control.
    public var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}

/// One custom key/value row in a props block — anything beyond the reserved
/// `tags` / `status` / `scheduled` / `due` fields.
public struct PropsField: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    public static func == (lhs: PropsField, rhs: PropsField) -> Bool {
        lhs.key == rhs.key && lhs.value == rhs.value
    }
}

/// Structured per-heading (or document-root) metadata: the schema surface that
/// smart-notes predicates and date detection query against (PUNK-4bz).
///
/// ## On-disk format
/// Under a heading a block serializes to a `> [!props]` Obsidian-style callout,
/// one field per line in `> key:: value` form. The **double** colon is the
/// Dataview inline-field convention; it lets a value keep single colons (times
/// like `15:00`, URLs) without ambiguity, since a line splits on its first `::`:
///
/// ```
/// > [!props]
/// > tags:: alpha, beta
/// > status:: doing
/// > scheduled:: 2026-07-10
/// > due:: 2026-07-15
/// > owner:: Mark
/// ```
///
/// At the document root the same fields live in YAML frontmatter (`key: value`,
/// tags as `[a, b]`). See ``HeadingProps`` for the document surgery.
///
/// Reserved keys are `tags`, `status`, `scheduled`, `due`; every other line is a
/// custom field, preserved in author order.
public struct PropsBlock: Sendable, Equatable {
    public var tags: [String]
    public var status: PropsStatus?
    /// Canonical date string (e.g. `2026-07-10` or `2026-07-10 15:00`), stored
    /// verbatim so the block round-trips losslessly. The inspector resolves
    /// natural-language input to this via ``NaturalDateParser``.
    public var scheduled: String?
    public var due: String?
    public var custom: [PropsField]

    /// Field keys the block handles specially; anything else is a custom row.
    public static let reservedKeys: Set<String> = ["tags", "status", "scheduled", "due"]

    public init(
        tags: [String] = [],
        status: PropsStatus? = nil,
        scheduled: String? = nil,
        due: String? = nil,
        custom: [PropsField] = []
    ) {
        self.tags = tags
        self.status = status
        self.scheduled = scheduled
        self.due = due
        self.custom = custom
    }

    /// True when the block carries no meaningful field — the signal that a
    /// callout should be removed rather than written.
    public var isEmpty: Bool {
        cleanedTags.isEmpty
            && status == nil
            && (scheduled?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            && (due?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            && cleanedCustom.isEmpty
    }

    // MARK: - Serialization

    /// The full `> [!props]` callout (header + field lines) with **no** trailing
    /// newline, or `nil` when the block is empty. ``HeadingProps`` owns the
    /// surrounding newline placement.
    public func calloutText() -> String? {
        let lines = fieldLines()
        guard !lines.isEmpty else { return nil }
        return (["> [!props]"] + lines.map { "> \($0)" }).joined(separator: "\n")
    }

    /// The ordered `key:: value` field lines (without the `> ` quote prefix).
    private func fieldLines() -> [String] {
        var lines: [String] = []
        let tags = cleanedTags
        if !tags.isEmpty { lines.append("tags:: \(tags.joined(separator: ", "))") }
        if let status { lines.append("status:: \(status.rawValue)") }
        if let scheduled = scheduled?.trimmingCharacters(in: .whitespaces), !scheduled.isEmpty {
            lines.append("scheduled:: \(scheduled)")
        }
        if let due = due?.trimmingCharacters(in: .whitespaces), !due.isEmpty {
            lines.append("due:: \(due)")
        }
        for field in cleanedCustom {
            lines.append("\(field.key):: \(field.value)")
        }
        return lines
    }

    /// Tags normalized the same way the ``Document`` boundary does: trimmed,
    /// lowercased, de-duplicated (order-preserving), empties dropped.
    private var cleanedTags: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            let clean = tag.trimmingCharacters(in: .whitespaces).lowercased()
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            result.append(clean)
        }
        return result
    }

    /// Custom rows with usable key + value, and reserved keys filtered out so a
    /// custom `status` row can't shadow the real field.
    private var cleanedCustom: [PropsField] {
        custom.compactMap { field in
            let key = field.key.trimmingCharacters(in: .whitespaces)
            let value = field.value.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty,
                  !PropsBlock.reservedKeys.contains(key.lowercased()) else { return nil }
            return PropsField(key: key, value: value)
        }
    }

    // MARK: - Parsing

    /// Parse callout text (the raw `> …` lines of a `[!props]` callout) into a
    /// block. Lines without `::`, and the `[!props]` header line, are skipped.
    /// Inverse of ``calloutText()`` for any non-empty block.
    public static func parseCallout(_ text: String) -> PropsBlock {
        var block = PropsBlock()
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(">") else { continue }
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            // Skip the callout header (`[!props]`, optionally `[!props]+ Title`).
            if line.lowercased().hasPrefix("[!props]") { continue }
            guard let sep = line.range(of: "::") else { continue }
            let key = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            block.assign(key: key, value: value)
        }
        return block
    }

    /// Assign one parsed `key:: value` pair, routing reserved keys to their
    /// typed fields and everything else to a custom row.
    private mutating func assign(key: String, value: String) {
        switch key.lowercased() {
        case "tags":
            tags = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        case "status":
            status = PropsStatus(rawValue: value.lowercased())
        case "scheduled":
            scheduled = value.isEmpty ? nil : value
        case "due":
            due = value.isEmpty ? nil : value
        default:
            guard !value.isEmpty else { return }
            custom.append(PropsField(key: key, value: value))
        }
    }
}
