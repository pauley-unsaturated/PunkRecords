import SwiftUI
import MarkdownUI
import PunkRecordsCore
import PunkRecordsInfra

/// Renders a markdown document with GitHub-flavored styling.
/// YAML frontmatter is stripped so the preview shows only the body.
struct MarkdownPreviewView: View {
    let content: String
    var theme: EditorTheme = .dracula

    private var renderedBody: String {
        MarkdownParser().parseFrontmatter(from: content).body
    }

    var body: some View {
        ScrollView {
            Markdown(renderedBody)
                .markdownTheme(.gitHub)
                .markdownCodeSyntaxHighlighter(
                    TreeSitterCodeSyntaxHighlighter(theme: theme.highlighterTheme)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("markdownPreview")
    }
}

#Preview("Markdown Preview — Sample") {
    MarkdownPreviewView(content: PreviewData.markdownSample)
        .frame(width: 700, height: 600)
}
