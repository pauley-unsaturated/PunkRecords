import Foundation

public typealias DocumentID = UUID
public typealias RelativePath = String

public struct Document: Identifiable, Hashable, Sendable {
    public let id: DocumentID
    public var title: String
    public var content: String
    public var path: RelativePath
    public var tags: [String]
    public var created: Date
    public var modified: Date
    public var frontmatter: [String: String]
    public var linkedDocumentIDs: [DocumentID]

    public init(
        id: DocumentID = UUID(),
        title: String,
        content: String,
        path: RelativePath,
        tags: [String] = [],
        created: Date = Date(),
        modified: Date = Date(),
        frontmatter: [String: String] = [:],
        linkedDocumentIDs: [DocumentID] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.path = path
        self.tags = tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        self.created = created
        self.modified = modified
        self.frontmatter = frontmatter
        self.linkedDocumentIDs = linkedDocumentIDs
    }

    public static func == (lhs: Document, rhs: Document) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Derives the title from content: H1 heading > frontmatter title > filename.
    public static func deriveTitle(
        content: String,
        frontmatter: [String: String],
        filename: String
    ) -> String {
        // Try H1 heading
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }

        // Try frontmatter title
        if let fmTitle = frontmatter["title"], !fmTitle.isEmpty {
            return fmTitle
        }

        // Fall back to filename without extension
        return (filename as NSString).deletingPathExtension
    }
}
