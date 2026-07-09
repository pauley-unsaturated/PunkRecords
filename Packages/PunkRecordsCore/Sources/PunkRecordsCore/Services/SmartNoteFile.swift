import Foundation

/// A saved user smart note: a display name plus its query. Persisted as
/// `Smart Notes/{name}.md` (see ``SmartNoteFile``).
public struct SmartNote: Equatable, Sendable, Identifiable {
    public var name: String
    public var query: SmartNoteQuery

    public init(name: String, query: SmartNoteQuery) {
        self.name = name
        self.query = query
    }

    /// The name doubles as the identity (also the file stem).
    public var id: String { name }
}

/// Reads and writes the on-disk smart-note file format: YAML frontmatter holding
/// the serialized query, and a body that is an auto-generated, human-readable
/// description of the query so the file is legible in any editor.
///
/// ```
/// ---
/// smartnote: 1
/// name: Today
/// query: {"root":{…},"version":1}
/// ---
///
/// status is not done and scheduled is on or before today
/// ```
public enum SmartNoteFile {

    /// Serialize `note` to its full file contents (with a trailing newline).
    public static func serialize(_ note: SmartNote) throws -> String {
        let json = try note.query.toJSON()
        let description = SmartNoteDescription.describe(note.query)
        return """
        ---
        smartnote: \(note.query.version)
        name: \(note.name)
        query: \(json)
        ---

        \(description)

        """
    }

    /// Parse file `content` back into a ``SmartNote``, rejecting a missing or
    /// unsupported schema version.
    public static func parse(_ content: String) throws -> SmartNote {
        let (frontmatter, _) = MarkdownParser().parseFrontmatter(from: content)

        guard let versionRaw = frontmatter["smartnote"], let version = Int(versionRaw) else {
            throw SmartNoteFileError.notASmartNote
        }
        guard (1...SmartNoteQuery.currentVersion).contains(version) else {
            throw SmartNoteFileError.unsupportedVersion(version)
        }
        guard let json = frontmatter["query"] else {
            throw SmartNoteFileError.missingQuery
        }

        let query = try SmartNoteQuery.fromJSON(json)
        let name = frontmatter["name"]?.trimmingCharacters(in: .whitespaces) ?? "Untitled"
        return SmartNote(name: name.isEmpty ? "Untitled" : name, query: query)
    }

    /// Whether a document at `path` is a smart-note file (lives under the
    /// Smart Notes directory).
    public static func isSmartNotePath(_ path: RelativePath) -> Bool {
        path.hasPrefix(VaultPaths.smartNotesDirectory + "/")
    }
}

/// Failure reading a smart-note file.
public enum SmartNoteFileError: Error, Equatable, Sendable {
    case notASmartNote
    case unsupportedVersion(Int)
    case missingQuery
}

// MARK: - Description

/// Renders a query as a short English phrase for the file body and UI subtitles.
/// Pure and unit-tested.
public enum SmartNoteDescription {
    public static func describe(_ query: SmartNoteQuery) -> String {
        describe(query.root, topLevel: true)
    }

    private static func describe(_ node: SmartNotePredicate, topLevel: Bool) -> String {
        switch node {
        case .comparison(let comparison):
            return describe(comparison)
        case .and(let children):
            return join(children, with: " and ", topLevel: topLevel)
        case .or(let children):
            return join(children, with: " or ", topLevel: topLevel)
        case .not(let child):
            return "not (\(describe(child, topLevel: true)))"
        }
    }

    private static func join(_ children: [SmartNotePredicate], with separator: String, topLevel: Bool) -> String {
        let parts = children.map { child -> String in
            switch child {
            case .comparison:
                return describe(child, topLevel: false)
            default:
                return "(\(describe(child, topLevel: true)))"
            }
        }
        let phrase = parts.joined(separator: separator)
        return topLevel ? phrase : "(\(phrase))"
    }

    private static func describe(_ comparison: SmartNoteComparison) -> String {
        let field = comparison.field.displayName
        let op = comparison.op.displayName
        if comparison.op.isExistence {
            return "\(field) \(op)"
        }
        return "\(field) \(op) \(comparison.value.displayName)"
    }
}
