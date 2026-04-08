import Foundation
import Testing
import PunkRecordsCore

/// Structural assertions for evaluating LLM-generated markdown.
/// These check that output conforms to the format we expect,
/// not that the content is "correct" in a subjective sense.
enum MarkdownAssertions {

    /// Checks that the text starts with YAML frontmatter (--- delimited).
    static func hasFrontmatter(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasPrefix("---"), "Expected frontmatter block starting with ---", sourceLocation: sourceLocation)
        let parts = trimmed.components(separatedBy: "---")
        // Should have at least 3 parts: empty before first ---, frontmatter, rest
        #expect(parts.count >= 3, "Expected closing --- for frontmatter block", sourceLocation: sourceLocation)
    }

    /// Checks that frontmatter contains a tags field with at least `minCount` tags.
    static func hasTags(_ text: String, minCount: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
        let parser = MarkdownParser()
        let (frontmatter, _) = parser.parseFrontmatter(from: text)
        let tags = parser.parseTags(from: frontmatter)
        #expect(
            tags.count >= minCount,
            "Expected at least \(minCount) tag(s), got \(tags.count): \(tags)",
            sourceLocation: sourceLocation
        )
    }

    /// Checks that the text contains an H1 heading.
    static func hasH1(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = text.components(separatedBy: .newlines)
        let hasHeading = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##")
        }
        #expect(hasHeading, "Expected an H1 heading (# Title)", sourceLocation: sourceLocation)
    }

    /// Checks that the text contains at least `minCount` wikilinks.
    static func hasWikilinks(_ text: String, minCount: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
        let parser = MarkdownParser()
        let wikilinks = parser.parseWikilinks(from: text)
        #expect(
            wikilinks.count >= minCount,
            "Expected at least \(minCount) wikilink(s), got \(wikilinks.count)",
            sourceLocation: sourceLocation
        )
    }

    /// Checks that the text has multiple sections (H2+ headings).
    static func hasSections(_ text: String, minCount: Int = 2, sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = text.components(separatedBy: .newlines)
        let sectionCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }.count
        #expect(
            sectionCount >= minCount,
            "Expected at least \(minCount) section(s) (## headings), got \(sectionCount)",
            sourceLocation: sourceLocation
        )
    }

    /// Checks minimum word count — ensures the LLM actually produced substantive content.
    static func hasMinimumLength(_ text: String, minWords: Int = 50, sourceLocation: SourceLocation = #_sourceLocation) {
        let wordCount = text.split(separator: " ").count
        #expect(
            wordCount >= minWords,
            "Expected at least \(minWords) words, got \(wordCount)",
            sourceLocation: sourceLocation
        )
    }

    /// Checks that the output doesn't contain common LLM meta-commentary.
    static func noMetaCommentary(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let banned = [
            "Here is the",
            "Here's the",
            "I've converted",
            "I have converted",
            "Sure, here",
            "Certainly!",
            "Of course!",
        ]
        for phrase in banned {
            #expect(
                !text.contains(phrase),
                "Output contains meta-commentary: \"\(phrase)\"",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Checks that the output is valid markdown that the parser can handle.
    static func parsesSuccessfully(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let parser = MarkdownParser()
        let result = parser.parse(content: text, filename: "eval-test")
        #expect(!result.title.isEmpty, "Parser should extract a title", sourceLocation: sourceLocation)
    }
}
