import Foundation

/// Pure helpers for deriving file paths and editing markdown headings.
/// Lives in Core so it's unit-testable without an app target.
public enum FilenameHelpers {

    /// Replace characters that aren't valid in a `.md` filename with `-`.
    public static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    /// Replace the first `# Heading` in the body (after any YAML frontmatter) with `# newTitle`.
    /// If no H1 exists in the body, insert one immediately after the frontmatter.
    /// H1-looking lines *inside* the frontmatter are not touched.
    public static func replaceFirstH1(in content: String, with newTitle: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var bodyStart = 0

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = i + 1
                break
            }
        }

        var result = Array(lines[0..<bodyStart])
        var replaced = false
        for i in bodyStart..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if !replaced && trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
                result.append("# \(newTitle)")
                replaced = true
            } else {
                result.append(lines[i])
            }
        }

        if !replaced {
            var insertAt = bodyStart
            while insertAt < result.count && result[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            result.insert("# \(newTitle)", at: insertAt)
            if insertAt + 1 >= result.count || !result[insertAt + 1].isEmpty {
                result.insert("", at: insertAt + 1)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Find an unused filename of the form `BaseName.md`, `BaseName 2.md`, `BaseName 3.md`…
    /// `exists` is an async predicate that returns whether a relative path already exists in the
    /// destination (e.g. the repository).
    public static func uniqueNotePath(
        baseName: String,
        exists: @Sendable (String) async -> Bool
    ) async -> String {
        var candidate = "\(baseName).md"
        var n = 2
        while await exists(candidate) {
            candidate = "\(baseName) \(n).md"
            n += 1
        }
        return candidate
    }
}
