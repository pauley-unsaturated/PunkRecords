import SwiftUI
import MarkdownUI
import PunkRecordsInfra

extension MarkdownUI.Theme {
    /// A MarkdownUI theme derived from the app's `EditorTheme`, so the read-only
    /// preview matches the live editor (background, text, headings, inline code,
    /// links) and is readable in both light and dark mode.
    @MainActor
    static func punk(_ editor: EditorTheme) -> MarkdownUI.Theme {
        let h = editor.highlighterTheme
        let foreground = Color(nsColor: editor.foreground)
        let secondary = Color(nsColor: h.dimColor)

        func headingColor(_ level: Int) -> Color {
            Color(nsColor: h.headingColors[level] ?? editor.foreground)
        }

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(foreground)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                ForegroundColor(Color(nsColor: h.codeColor))
                BackgroundColor(Color(nsColor: h.codeBackground))
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(Color(nsColor: h.linkColor)) }
            .heading1 { Self.heading($0, size: 2.0, color: headingColor(1), rule: true) }
            .heading2 { Self.heading($0, size: 1.5, color: headingColor(2), rule: true) }
            .heading3 { Self.heading($0, size: 1.25, color: headingColor(3), rule: false) }
            .heading4 { Self.heading($0, size: 1.0, color: headingColor(4), rule: false) }
            .heading5 { Self.heading($0, size: 0.875, color: headingColor(5), rule: false) }
            .heading6 { Self.heading($0, size: 0.85, color: headingColor(6), rule: false) }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(secondary) }
                    .relativePadding(.leading, length: .em(1))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(secondary.opacity(0.4))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 8, bottom: 8)
            }
    }

    @MainActor
    @ViewBuilder
    private static func heading(
        _ configuration: BlockConfiguration,
        size: Double,
        color: Color,
        rule: Bool
    ) -> some View {
        if rule {
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativePadding(.bottom, length: .em(0.3))
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(size))
                        ForegroundColor(color)
                    }
                Divider().overlay(color.opacity(0.3))
            }
        } else {
            configuration.label
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(size))
                    ForegroundColor(color)
                }
        }
    }
}
