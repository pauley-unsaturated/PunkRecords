import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("TreeSitterMarkdownHighlighter Tests")
struct TreeSitterMarkdownHighlighterTests {
    // MARK: - Attribute mapping (pure function)

    @Test("Heading token maps to bold heading attributes")
    func headingAttributes() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "text.title")
        let font = attrs[.font] as? NSFont
        #expect(font != nil)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("Strong token is bold")
    func strongAttributes() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "text.strong")
        let font = attrs[.font] as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("Emphasis token is italic")
    func emphasisAttributes() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "text.emphasis")
        let font = attrs[.font] as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    @Test("Code literal gets distinctive foreground + background")
    func literalAttributes() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "text.literal")
        #expect(attrs[.foregroundColor] != nil)
        #expect(attrs[.backgroundColor] != nil)
    }

    @Test("URI token underlined and colored")
    func uriAttributes() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "text.uri")
        #expect(attrs[.underlineStyle] != nil)
        #expect(attrs[.foregroundColor] != nil)
    }

    @Test("Unknown token returns empty attributes")
    func unknownTokenIsEmpty() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "no.such.token")
        #expect(attrs.isEmpty)
    }

    @Test("Code-fence content token is intentionally unstyled")
    func noneTokenIsEmpty() {
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "none")
        #expect(attrs.isEmpty)
    }

    // MARK: - Language configuration loading

    @Test("Markdown LanguageConfiguration loads with bundled queries")
    func markdownConfigLoads() throws {
        let config = try TreeSitterMarkdownHighlighter.makeMarkdownConfiguration()
        #expect(config.name == "Markdown")
        // Highlights query must be discoverable from the SPM-bundled resources.
        #expect(config.queries.keys.isEmpty == false)
    }

    @Test("Inline MarkdownInline LanguageConfiguration loads")
    func inlineConfigLoads() throws {
        let config = try TreeSitterMarkdownHighlighter.makeInlineConfiguration()
        #expect(config.name == "MarkdownInline")
        #expect(config.queries.keys.isEmpty == false)
    }

    @Test("Language provider resolves the inline grammar by name")
    func languageProviderResolvesInline() {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        #expect(provider("markdown_inline") != nil)
        #expect(provider("MarkdownInline") != nil)
        #expect(provider("inline") != nil)
    }

    @Test("Language provider returns nil for unknown injections")
    func languageProviderReturnsNilForUnknown() {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        #expect(provider("swift") == nil)
        #expect(provider("python") == nil)
    }

    // MARK: - Integration with NSTextView (smoke test)

    @Test("Highlighter installs onto an NSTextView without throwing")
    func installsOnTextView() throws {
        let textView = NSTextView()
        textView.string = "# Heading\n\nSome **bold** text with `code`."
        let highlighter = try TreeSitterMarkdownHighlighter(textView: textView)
        #expect(highlighter.theme.bodyFont.pointSize == 14)
    }

    @Test("Highlighter handles a CommonMark + GFM corpus end-to-end")
    func corpusEndToEnd() throws {
        let corpus = """
        # H1
        ## H2
        ### H3

        Paragraph with *emphasis* and **strong** and `code`.

        > Block quote.

        - bullet one
        - bullet two
        + plus
        * star

        1. ordered
        2. items

        ---

        ```swift
        let x = 42
        ```

        Visit [example](https://example.com) or use <https://example.org>.

        | a | b |
        |---|---|
        | 1 | 2 |

        \\* escaped asterisk and a hard line break  \nfollows.
        """
        let textView = NSTextView()
        textView.string = corpus
        _ = try TreeSitterMarkdownHighlighter(textView: textView)
        // No throw == grammar accepted everything in the corpus.
    }
}
