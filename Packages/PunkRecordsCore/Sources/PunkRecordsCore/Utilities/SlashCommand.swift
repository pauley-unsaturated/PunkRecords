import Foundation

/// A single insertable command in the editor's `/` palette.
public struct SlashCommand: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    /// Text inserted in place of the `/query`.
    public let snippet: String
    /// Caret offset (UTF-16) from the start of `snippet` after insertion.
    /// Lets a command drop the caret in a sensible spot (e.g. inside `[[]]`).
    public let caretOffset: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        snippet: String,
        caretOffset: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.snippet = snippet
        self.caretOffset = caretOffset
    }
}

/// Built-in command set for the editor's slash palette, plus the pure
/// trigger-detection and filtering logic (kept here so it's unit-testable
/// without an NSTextView).
public enum SlashCommandLibrary {
    public static let all: [SlashCommand] = [
        SlashCommand(id: "h1", title: "Heading 1", subtitle: "Large section title",
                     systemImage: "textformat.size.larger", snippet: "# ", caretOffset: 2),
        SlashCommand(id: "h2", title: "Heading 2", subtitle: "Medium section title",
                     systemImage: "textformat.size", snippet: "## ", caretOffset: 3),
        SlashCommand(id: "h3", title: "Heading 3", subtitle: "Small section title",
                     systemImage: "textformat.size.smaller", snippet: "### ", caretOffset: 4),
        SlashCommand(id: "bullet", title: "Bulleted List", subtitle: "Unordered list item",
                     systemImage: "list.bullet", snippet: "- ", caretOffset: 2),
        SlashCommand(id: "numbered", title: "Numbered List", subtitle: "Ordered list item",
                     systemImage: "list.number", snippet: "1. ", caretOffset: 3),
        SlashCommand(id: "task", title: "Task", subtitle: "Checklist item",
                     systemImage: "checklist", snippet: "- [ ] ", caretOffset: 6),
        SlashCommand(id: "quote", title: "Quote", subtitle: "Block quotation",
                     systemImage: "text.quote", snippet: "> ", caretOffset: 2),
        SlashCommand(id: "code", title: "Code Block", subtitle: "Fenced code block",
                     systemImage: "curlybraces", snippet: "```\n\n```\n", caretOffset: 4),
        SlashCommand(id: "table", title: "Table", subtitle: "Markdown table skeleton",
                     systemImage: "tablecells",
                     snippet: "| Column | Column |\n| --- | --- |\n| | |\n", caretOffset: 2),
        SlashCommand(id: "divider", title: "Divider", subtitle: "Horizontal rule",
                     systemImage: "minus", snippet: "---\n", caretOffset: 4),
        SlashCommand(id: "wikilink", title: "Wikilink", subtitle: "Link to another note",
                     systemImage: "link", snippet: "[[]]", caretOffset: 2),
        SlashCommand(id: "math", title: "Math Block", subtitle: "Block LaTeX formula",
                     systemImage: "function", snippet: "$$\n\n$$\n", caretOffset: 3),
        SlashCommand(id: "callout", title: "Callout", subtitle: "Highlighted note block",
                     systemImage: "exclamationmark.bubble", snippet: "> [!NOTE]\n> ", caretOffset: 12),
    ]

    /// Fuzzy-filter commands by query (the text typed after `/`). Empty query
    /// returns the full list in declaration order. Matching is a case-insensitive
    /// subsequence over the title.
    public static func filter(_ query: String) -> [SlashCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let needle = Array(trimmed.lowercased())
        return all.filter { command in
            isSubsequence(needle, of: Array(command.title.lowercased()))
                || command.id.lowercased().hasPrefix(trimmed.lowercased())
        }
    }

    /// Detects whether a slash-command session is active given the full text and
    /// caret location. Returns the query (text between the triggering `/` and the
    /// caret) and the range of `/query` to be replaced on insertion.
    ///
    /// The trigger is a `/` at the very start of a line or immediately after
    /// whitespace, with no whitespace between it and the caret.
    public static func activeSession(
        in text: String,
        caretLocation: Int
    ) -> (query: String, replaceRange: Range<Int>)? {
        let chars = Array(text.utf16)
        guard caretLocation <= chars.count, caretLocation >= 0 else { return nil }

        // Walk back from the caret to find a `/`. Bail if we hit whitespace
        // or newline first (the query can't contain spaces).
        var i = caretLocation - 1
        while i >= 0 {
            let c = chars[i]
            if c == 0x2F { // '/'
                // Char before the slash must be start-of-text, whitespace, or newline.
                let before: UInt16? = i > 0 ? chars[i - 1] : nil
                let validStart = before == nil
                    || before == 0x20 // space
                    || before == 0x0A // newline
                    || before == 0x09 // tab
                if validStart {
                    let query = String(utf16CodeUnits: Array(chars[(i + 1)..<caretLocation]), count: caretLocation - (i + 1))
                    return (query, i..<caretLocation)
                }
                return nil
            }
            if c == 0x20 || c == 0x0A || c == 0x09 {
                return nil // whitespace before any slash — no active session
            }
            i -= 1
        }
        return nil
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        guard !needle.isEmpty else { return true }
        var n = 0
        for c in haystack {
            if c == needle[n] {
                n += 1
                if n == needle.count { return true }
            }
        }
        return false
    }
}
