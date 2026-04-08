import Testing
import Foundation
import PunkRecordsCore
@testable import PunkRecordsInfra

@Suite("RegexSyntaxHighlighter Tests")
struct RegexSyntaxHighlighterTests {
    let highlighter = RegexSyntaxHighlighter()

    // MARK: - Helpers

    /// Find highlights matching a given style predicate.
    private func highlights(
        in text: String,
        matching predicate: (HighlightStyle) -> Bool
    ) -> [SyntaxHighlight] {
        highlighter.highlight(text).filter { predicate($0.style) }
    }

    /// Extract the substring for a highlight from the original text.
    private func substring(of highlight: SyntaxHighlight, in text: String) -> String {
        let nsText = text as NSString
        return nsText.substring(with: highlight.range)
    }

    // MARK: - Empty Input

    @Test("Empty string returns no highlights")
    func emptyString() {
        let results = highlighter.highlight("")
        #expect(results.isEmpty)
    }

    // MARK: - Headers

    @Test("H1 through H6 detected with correct level")
    func headersH1ThroughH6() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let text = "\(hashes) Heading Level \(level)"
            let results = highlights(in: text) {
                if case .heading = $0 { return true }
                return false
            }
            #expect(results.count == 1, "Expected 1 heading highlight for H\(level)")
            if case .heading(let detected) = results.first?.style {
                #expect(detected == level, "Expected level \(level), got \(detected)")
            } else {
                Issue.record("Expected heading style for H\(level)")
            }
        }
    }

    @Test("Header highlight covers the full line")
    func headerFullRange() {
        let text = "## My Title"
        let results = highlights(in: text) {
            if case .heading = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "## My Title")
    }

    // MARK: - Bold

    @Test("Bold with double asterisks")
    func boldAsterisks() {
        let text = "some **bold** text"
        let results = highlights(in: text) {
            if case .bold = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "**bold**")
    }

    @Test("Bold with double underscores")
    func boldUnderscores() {
        let text = "some __bold__ text"
        let results = highlights(in: text) {
            if case .bold = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "__bold__")
    }

    // MARK: - Italic

    @Test("Italic with single asterisk")
    func italicAsterisk() {
        let text = "some *italic* text"
        let results = highlights(in: text) {
            if case .italic = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "*italic*")
    }

    @Test("Italic with single underscore")
    func italicUnderscore() {
        let text = "some _italic_ text"
        let results = highlights(in: text) {
            if case .italic = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "_italic_")
    }

    // MARK: - Strikethrough

    @Test("Strikethrough with double tildes")
    func strikethrough() {
        let text = "some ~~struck~~ text"
        let results = highlights(in: text) {
            if case .strikethrough = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "~~struck~~")
    }

    // MARK: - Inline Code

    @Test("Inline code with backticks")
    func inlineCode() {
        let text = "use `let x = 1` here"
        let results = highlights(in: text) {
            if case .inlineCode = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "`let x = 1`")
    }

    // MARK: - Fenced Code Blocks

    @Test("Fenced code block detected with language identifier")
    func fencedCodeBlock() {
        let text = "```swift\nlet x = 1\n```"
        let all = highlighter.highlight(text)

        let codeBlocks = all.filter {
            if case .codeBlock = $0.style { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        #expect(substring(of: codeBlocks[0], in: text) == text)

        let languages = all.filter {
            if case .codeBlockLanguage = $0.style { return true }
            return false
        }
        #expect(languages.count == 1)
        #expect(substring(of: languages[0], in: text) == "swift")
    }

    @Test("Fenced code block without language identifier has no language highlight")
    func fencedCodeBlockNoLanguage() {
        let text = "```\nsome code\n```"
        let all = highlighter.highlight(text)

        let codeBlocks = all.filter {
            if case .codeBlock = $0.style { return true }
            return false
        }
        #expect(codeBlocks.count == 1)

        let languages = all.filter {
            if case .codeBlockLanguage = $0.style { return true }
            return false
        }
        #expect(languages.isEmpty)
    }

    // MARK: - Blockquotes

    @Test("Blockquote detected")
    func blockquote() {
        let text = "> This is a quote"
        let results = highlights(in: text) {
            if case .blockquote = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "> This is a quote")
    }

    // MARK: - Wikilinks

    @Test("Simple wikilink detected")
    func wikilinkSimple() {
        let text = "See [[MyPage]] for details"
        let results = highlights(in: text) {
            if case .wikilink = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "[[MyPage]]")
    }

    @Test("Wikilink with display text detected")
    func wikilinkWithDisplay() {
        let text = "See [[MyPage|custom label]] here"
        let results = highlights(in: text) {
            if case .wikilink = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "[[MyPage|custom label]]")
    }

    // MARK: - Markdown Links

    @Test("Markdown link detected")
    func markdownLink() {
        let text = "Click [here](https://example.com) now"
        let results = highlights(in: text) {
            if case .link = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "[here](https://example.com)")
    }

    // MARK: - List Markers

    @Test("Dash list marker detected")
    func dashListMarker() {
        let text = "- item one"
        let results = highlights(in: text) {
            if case .listMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "-")
    }

    @Test("Asterisk list marker detected")
    func asteriskListMarker() {
        let text = "* item one"
        let results = highlights(in: text) {
            if case .listMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "*")
    }

    @Test("Plus list marker detected")
    func plusListMarker() {
        let text = "+ item one"
        let results = highlights(in: text) {
            if case .listMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "+")
    }

    @Test("Ordered list marker detected")
    func orderedListMarker() {
        let text = "1. first item"
        let results = highlights(in: text) {
            if case .listMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text) == "1.")
    }

    // MARK: - Task Markers

    @Test("Unchecked task marker detected")
    func uncheckedTaskMarker() {
        let text = "- [ ] todo item"
        let results = highlights(in: text) {
            if case .taskMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text).contains("[ ]"))
    }

    @Test("Checked task marker detected")
    func checkedTaskMarker() {
        let text = "- [x] done item"
        let results = highlights(in: text) {
            if case .taskMarker = $0 { return true }
            return false
        }
        #expect(results.count == 1)
        #expect(substring(of: results[0], in: text).contains("[x]"))
    }

    // MARK: - Horizontal Rules

    @Test("Horizontal rule with dashes")
    func horizontalRuleDashes() {
        let text = "---"
        let results = highlights(in: text) {
            if case .horizontalRule = $0 { return true }
            return false
        }
        #expect(results.count == 1)
    }

    @Test("Horizontal rule with asterisks")
    func horizontalRuleAsterisks() {
        let text = "***"
        let results = highlights(in: text) {
            if case .horizontalRule = $0 { return true }
            return false
        }
        #expect(results.count == 1)
    }

    @Test("Horizontal rule with underscores")
    func horizontalRuleUnderscores() {
        let text = "___"
        let results = highlights(in: text) {
            if case .horizontalRule = $0 { return true }
            return false
        }
        #expect(results.count == 1)
    }

    // MARK: - Incremental Highlight

    @Test("incrementalHighlight falls back to full highlight")
    func incrementalHighlightFallback() {
        let text = "## Hello"
        let full = highlighter.highlight(text)
        let incremental = highlighter.incrementalHighlight(text, editedRange: NSRange(location: 0, length: 5))

        #expect(full.count == incremental.count)
        for (f, i) in zip(full, incremental) {
            #expect(f.range == i.range)
        }
    }
}
