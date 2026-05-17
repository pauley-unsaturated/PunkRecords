import SwiftUI
import MarkdownUI
import PunkRecordsCore

/// Renders a markdown document with GitHub-flavored styling.
/// YAML frontmatter is stripped so the preview shows only the body.
struct MarkdownPreviewView: View {
    let content: String

    private var renderedBody: String {
        MarkdownParser().parseFrontmatter(from: content).body
    }

    var body: some View {
        ScrollView {
            Markdown(renderedBody)
                .markdownTheme(.gitHub)
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
