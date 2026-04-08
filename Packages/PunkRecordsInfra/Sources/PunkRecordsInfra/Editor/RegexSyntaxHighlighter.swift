import Foundation
import AppKit
import PunkRecordsCore

/// Regex-based syntax highlighter for raw Markdown editing.
/// Implements the SyntaxHighlighter protocol so it can be swapped for TreeSitter later.
public final class RegexSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func highlight(_ text: String) -> [SyntaxHighlight] {
        var highlights: [SyntaxHighlight] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Headers: # through ######
        applyPattern(#"^(#{1,6})\s+(.+)$"#, to: nsText, in: fullRange) { match in
            let hashes = nsText.substring(with: match.range(at: 1))
            let level = hashes.count
            highlights.append(SyntaxHighlight(range: match.range, style: .heading(level: level)))
        }

        // Bold: **text** or __text__
        applyPattern(#"(\*\*|__)(.+?)\1"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .bold))
        }

        // Italic: *text* or _text_ (but not ** or __)
        applyPattern(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .italic))
        }
        applyPattern(#"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .italic))
        }

        // Strikethrough: ~~text~~
        applyPattern(#"~~(.+?)~~"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .strikethrough))
        }

        // Inline code: `text`
        applyPattern(#"`([^`\n]+)`"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .inlineCode))
        }

        // Fenced code blocks: ```language\n...\n```
        applyPattern(#"```(\w*)\n[\s\S]*?```"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .codeBlock))
            if match.numberOfRanges > 1 {
                let langRange = match.range(at: 1)
                if langRange.length > 0 {
                    highlights.append(SyntaxHighlight(range: langRange, style: .codeBlockLanguage))
                }
            }
        }

        // Blockquotes: > text
        applyPattern(#"^>\s+(.+)$"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .blockquote))
        }

        // Wikilinks: [[target]] or [[target|display]]
        applyPattern(#"\[\[([^\]]+)\]\]"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .wikilink))
        }

        // Markdown links: [text](url)
        applyPattern(#"\[([^\]]*)\]\(([^)]+)\)"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .link))
        }

        // List markers: - or * or 1.
        applyPattern(#"^(\s*)([-*+]|\d+\.)\s"#, to: nsText, in: fullRange) { match in
            if match.numberOfRanges > 2 {
                highlights.append(SyntaxHighlight(range: match.range(at: 2), style: .listMarker))
            }
        }

        // Task markers: - [ ] or - [x]
        applyPattern(#"^(\s*[-*+]\s)\[([ xX])\]"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .taskMarker))
        }

        // Horizontal rules: --- or *** or ___
        applyPattern(#"^([-*_]{3,})\s*$"#, to: nsText, in: fullRange) { match in
            highlights.append(SyntaxHighlight(range: match.range, style: .horizontalRule))
        }

        return highlights
    }

    public func incrementalHighlight(_ text: String, editedRange: NSRange) -> [SyntaxHighlight] {
        // For Phase 1, just re-highlight the full text.
        // Incremental optimization can come later.
        highlight(text)
    }

    // MARK: - Private

    private func applyPattern(
        _ pattern: String,
        to text: NSString,
        in range: NSRange,
        options: NSRegularExpression.Options = [.anchorsMatchLines],
        handler: (NSTextCheckingResult) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let matches = regex.matches(in: text as String, range: range)
        for match in matches {
            handler(match)
        }
    }
}
