import SwiftUI
import MarkdownUI
import PunkRecordsCore
import PunkRecordsInfra

/// Renders a markdown document with GitHub-flavored styling.
/// YAML frontmatter is stripped so the preview shows only the body.
struct MarkdownPreviewView: View {
    let content: String
    var theme: EditorTheme = .dracula
    /// Invoked when a `[[wikilink]]` is clicked, with the resolved target title.
    var onOpenNote: (String) -> Void = { _ in }
    /// Invoked when a `#tag` is clicked, with the tag name (no leading `#`).
    var onOpenTag: (String) -> Void = { _ in }

    private var renderedBody: String {
        PreviewLinkRewriter.rewrite(MarkdownParser().parseFrontmatter(from: content).body)
    }

    var body: some View {
        ScrollView {
            Markdown(renderedBody)
                .markdownTheme(.punk(theme))
                .markdownCodeSyntaxHighlighter(
                    TreeSitterCodeSyntaxHighlighter(theme: theme.highlighterTheme)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(Color(nsColor: theme.background))
        .accessibilityIdentifier("markdownPreview")
        .environment(\.openURL, OpenURLAction(handler: handleLink))
    }

    /// Route `punk://` links to in-app navigation; everything else opens
    /// externally via the system default (browser).
    private func handleLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == PreviewLinkRewriter.scheme else { return .systemAction }
        let value = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        switch url.host {
        case PreviewLinkRewriter.noteHost:
            onOpenNote(value)
            return .handled
        case PreviewLinkRewriter.tagHost:
            onOpenTag(value)
            return .handled
        default:
            return .discarded
        }
    }
}

#Preview("Markdown Preview — Sample") {
    MarkdownPreviewView(content: PreviewData.markdownSample)
        .frame(width: 700, height: 600)
}
