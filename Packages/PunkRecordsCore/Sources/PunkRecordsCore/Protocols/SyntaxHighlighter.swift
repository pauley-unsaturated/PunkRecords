import Foundation

public enum HighlightStyle: Sendable {
    case heading(level: Int)
    case bold
    case italic
    case boldItalic
    case strikethrough
    case inlineCode
    case codeBlock
    case codeBlockLanguage
    case blockquote
    case link
    case wikilink
    case unresolvedWikilink
    case tag
    case listMarker
    case taskMarker
    case horizontalRule
}

public struct SyntaxHighlight: Sendable {
    public let range: NSRange
    public let style: HighlightStyle

    public init(range: NSRange, style: HighlightStyle) {
        self.range = range
        self.style = style
    }
}

public protocol SyntaxHighlighter: Sendable {
    func highlight(_ text: String) -> [SyntaxHighlight]
    func incrementalHighlight(_ text: String, editedRange: NSRange) -> [SyntaxHighlight]
}
