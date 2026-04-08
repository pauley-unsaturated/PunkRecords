import Foundation
import cmark_gfm

/// Parses Markdown documents using cmark-gfm. Extracts frontmatter, links, and wikilinks.
public struct MarkdownParser: Sendable {
    public init() {}

    // MARK: - Frontmatter

    public func parseFrontmatter(from content: String) -> (frontmatter: [String: String], body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return ([:], content)
        }

        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], content)
        }

        var frontmatterLines: [String] = []
        var closingIndex: Int?

        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
            frontmatterLines.append(lines[i])
        }

        guard let endIndex = closingIndex else {
            return ([:], content)
        }

        var fm: [String: String] = [:]
        for line in frontmatterLines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fm[key] = value
        }

        let bodyLines = Array(lines[(endIndex + 1)...])
        let body = bodyLines.joined(separator: "\n")

        return (fm, body)
    }

    // MARK: - Tags

    public func parseTags(from frontmatter: [String: String]) -> [String] {
        guard let tagsValue = frontmatter["tags"] else { return [] }
        // Handle both [tag1, tag2] and tag1, tag2 formats
        let cleaned = tagsValue
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return cleaned.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Wikilinks

    public func parseWikilinks(from content: String) -> [Wikilink] {
        var results: [Wikilink] = []
        let pattern = #"\[\[([^\]]+)\]\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let inner = nsContent.substring(with: match.range(at: 1))
            if inner.contains("|") {
                let parts = inner.split(separator: "|", maxSplits: 1)
                let target = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let display = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
                results.append(Wikilink(target: target, displayText: display))
            } else {
                results.append(Wikilink(target: inner.trimmingCharacters(in: .whitespaces)))
            }
        }

        return results
    }

    // MARK: - Markdown Links

    public func parseMarkdownLinks(from content: String) -> [MarkdownLink] {
        var results: [MarkdownLink] = []
        let pattern = #"\[([^\]]*)\]\(([^)]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let text = nsContent.substring(with: match.range(at: 1))
            let url = nsContent.substring(with: match.range(at: 2))
            results.append(MarkdownLink(text: text, url: url))
        }

        return results
    }

    // MARK: - Full Parse

    /// Parses a raw markdown string into its component parts.
    public func parse(content: String, filename: String) -> ParsedDocument {
        let (frontmatter, body) = parseFrontmatter(from: content)
        let tags = parseTags(from: frontmatter)
        let wikilinks = parseWikilinks(from: body)
        let markdownLinks = parseMarkdownLinks(from: body)
        let title = Document.deriveTitle(content: body, frontmatter: frontmatter, filename: filename)

        let id: DocumentID
        if let idString = frontmatter["id"], let parsed = UUID(uuidString: idString) {
            id = parsed
        } else {
            id = UUID()
        }

        return ParsedDocument(
            id: id,
            title: title,
            body: body,
            frontmatter: frontmatter,
            tags: tags,
            wikilinks: wikilinks,
            markdownLinks: markdownLinks,
            needsIDAssigned: frontmatter["id"] == nil
        )
    }

    // MARK: - Frontmatter Generation

    public func generateFrontmatter(
        id: DocumentID,
        tags: [String] = [],
        created: Date = Date(),
        modified: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("created: \(formatter.string(from: created))")
        lines.append("modified: \(formatter.string(from: modified))")
        if !tags.isEmpty {
            lines.append("tags: [\(tags.joined(separator: ", "))]")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Link Types

public struct Wikilink: Sendable, Equatable {
    public let target: String
    public let displayText: String?

    public init(target: String, displayText: String? = nil) {
        self.target = target
        self.displayText = displayText
    }
}

public struct MarkdownLink: Sendable, Equatable {
    public let text: String
    public let url: String

    public init(text: String, url: String) {
        self.text = text
        self.url = url
    }
}

// MARK: - ParsedDocument

public struct ParsedDocument: Sendable {
    public let id: DocumentID
    public let title: String
    public let body: String
    public let frontmatter: [String: String]
    public let tags: [String]
    public let wikilinks: [Wikilink]
    public let markdownLinks: [MarkdownLink]
    public let needsIDAssigned: Bool

    public init(
        id: DocumentID,
        title: String,
        body: String,
        frontmatter: [String: String],
        tags: [String],
        wikilinks: [Wikilink],
        markdownLinks: [MarkdownLink],
        needsIDAssigned: Bool
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.frontmatter = frontmatter
        self.tags = tags
        self.wikilinks = wikilinks
        self.markdownLinks = markdownLinks
        self.needsIDAssigned = needsIDAssigned
    }
}
