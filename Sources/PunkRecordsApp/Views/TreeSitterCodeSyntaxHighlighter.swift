import SwiftUI
import AppKit
import MarkdownUI
import PunkRecordsInfra

/// MarkdownUI code-block highlighter backed by the same tree-sitter grammars
/// and color theme the editor uses, so fenced code looks identical in the
/// read-only preview and the live editor.
///
/// MarkdownUI hands each code block to `highlightCode(_:language:)`; we resolve
/// the language statically (parse + highlights query, no live NSTextView) and
/// build a colored `Text`. Unsupported or unlabeled languages fall back to
/// plain monospaced text.
struct TreeSitterCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    let theme: TreeSitterMarkdownHighlighter.Theme

    func highlightCode(_ code: String, language: String?) -> Text {
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.bodyColor]
        )

        if let language,
           let spans = TreeSitterMarkdownHighlighter.codeHighlightSpans(for: code, language: language) {
            // Apply longest spans first so smaller, more-specific captures
            // (e.g. a function name inside a call expression) win.
            for span in spans.sorted(by: { $0.range.length > $1.range.length }) {
                let end = span.range.location + span.range.length
                guard span.range.location >= 0, end <= attributed.length else { continue }
                if let color = TreeSitterMarkdownHighlighter
                    .attributes(for: span.captureName, theme: theme)[.foregroundColor] as? NSColor {
                    attributed.addAttribute(.foregroundColor, value: color, range: span.range)
                }
            }
        }

        return Text(AttributedString(attributed))
    }
}
