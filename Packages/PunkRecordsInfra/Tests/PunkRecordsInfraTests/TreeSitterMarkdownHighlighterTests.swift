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

    @Test("Language provider returns nil for unsupported injections")
    func languageProviderReturnsNilForUnknown() {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        #expect(provider("haskell") == nil)
        #expect(provider("ruby") == nil)
        #expect(provider("go") == nil)
        #expect(provider("") == nil)
    }

    // MARK: - Injected code grammars

    @Test("Language provider resolves swift/python/javascript fences")
    func languageProviderResolvesCode() {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        #expect(provider("swift") != nil)
        #expect(provider("python") != nil)
        #expect(provider("py") != nil)
        #expect(provider("javascript") != nil)
        #expect(provider("js") != nil)
        #expect(provider("JavaScript") != nil) // case-insensitive
    }

    @Test("Language provider resolves typescript/rust/c/cpp/bash/json fences and aliases")
    func languageProviderResolvesAddedCode() {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        #expect(provider("typescript") != nil)
        #expect(provider("ts") != nil)
        #expect(provider("rust") != nil)
        #expect(provider("rs") != nil)
        #expect(provider("c") != nil)
        #expect(provider("cpp") != nil)
        #expect(provider("c++") != nil)
        #expect(provider("CPP") != nil) // case-insensitive
        #expect(provider("bash") != nil)
        #expect(provider("sh") != nil)
        #expect(provider("json") != nil)
    }

    @Test("Each code grammar config loads its bundled highlight queries")
    func codeConfigsLoadQueries() throws {
        let provider = TreeSitterMarkdownHighlighter.makeLanguageProvider()
        for lang in ["swift", "python", "javascript", "rust", "c", "typescript", "cpp", "bash", "json"] {
            let config = try #require(provider(lang), "\(lang) should resolve")
            #expect(config.queries.keys.isEmpty == false, "\(lang) should bundle highlight queries")
        }
    }

    @Test("Inherited TypeScript query merges JavaScript base rules (comment, string)")
    func typescriptMergesJavaScriptRules() throws {
        // TS-only highlights.scm carries no "comment"/"string" rules — they come
        // from the JavaScript parent. Their presence proves the merge worked.
        let names = try #require(TreeSitterMarkdownHighlighter.highlightsCaptureNames(forFence: "typescript"))
        #expect(names.contains("comment"))
        #expect(names.contains("string"))
        #expect(names.contains("type")) // and the TS-specific additions too
    }

    @Test("Inherited C++ query merges C base rules (comment)")
    func cppMergesCRules() throws {
        let names = try #require(TreeSitterMarkdownHighlighter.highlightsCaptureNames(forFence: "cpp"))
        #expect(names.contains("comment"))
    }

    @Test("Code captures map to the theme's code palette by leading component")
    func codeColorMapping() {
        let theme = TreeSitterMarkdownHighlighter.Theme(
            codeColors: ["keyword": .systemPink, "string": .systemYellow]
        )
        // Leading component matches.
        #expect(TreeSitterMarkdownHighlighter.codeColor(for: "keyword", theme: theme) == .systemPink)
        #expect(TreeSitterMarkdownHighlighter.codeColor(for: "keyword.function", theme: theme) == .systemPink)
        #expect(TreeSitterMarkdownHighlighter.codeColor(for: "string.special", theme: theme) == .systemYellow)
        // Recognized code root without a palette entry falls back to codeColor.
        #expect(TreeSitterMarkdownHighlighter.codeColor(for: "function", theme: theme) == theme.codeColor)
        // Non-code captures return nil (handled by markdown cases instead).
        #expect(TreeSitterMarkdownHighlighter.codeColor(for: "nonsense", theme: theme) == nil)
    }

    @Test("attributes() colors a code keyword via the palette")
    func codeKeywordAttributes() {
        let theme = TreeSitterMarkdownHighlighter.Theme(codeColors: ["keyword": .systemPink])
        let attrs = TreeSitterMarkdownHighlighter.attributes(for: "keyword.function", theme: theme)
        #expect(attrs[.foregroundColor] as? NSColor == .systemPink)
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
