import AppKit
import Foundation

/// A complete color theme for the editor surface — bundles the background,
/// base foreground, tree-sitter token colors, hybrid-UX decoration colors, and
/// wikilink/tag pill colors so a single value configures the whole editor.
///
/// Custom, user-defined themes are tracked separately (see the themes backlog
/// issue); for now the editor ships a built-in `.dracula` preset and a system
/// `.default`.
public struct EditorTheme: @unchecked Sendable {
    public var background: NSColor
    /// Base body foreground — used for the text view's typingAttributes and the
    /// decorator's body-color fill.
    public var foreground: NSColor
    public var insertionPoint: NSColor
    public var highlighterTheme: TreeSitterMarkdownHighlighter.Theme
    public var decoratorStyle: HybridUXDecorator.Style
    public var wikilinkStyle: WikilinkDecorator.Style

    public init(
        background: NSColor,
        foreground: NSColor,
        insertionPoint: NSColor,
        highlighterTheme: TreeSitterMarkdownHighlighter.Theme,
        decoratorStyle: HybridUXDecorator.Style,
        wikilinkStyle: WikilinkDecorator.Style
    ) {
        self.background = background
        self.foreground = foreground
        self.insertionPoint = insertionPoint
        self.highlighterTheme = highlighterTheme
        self.decoratorStyle = decoratorStyle
        self.wikilinkStyle = wikilinkStyle
    }

    public var bodyFont: NSFont { highlighterTheme.bodyFont }

    // MARK: - System default (adapts to light/dark via dynamic system colors)

    public static let `default` = EditorTheme(
        background: .textBackgroundColor,
        foreground: .textColor,
        insertionPoint: .textColor,
        highlighterTheme: .default,
        decoratorStyle: .default,
        wikilinkStyle: .default
    )

    // MARK: - Dracula

    public static let dracula: EditorTheme = {
        let bg = NSColor(hex: 0x282A36)
        let currentLine = NSColor(hex: 0x44475A)
        let foreground = NSColor(hex: 0xF8F8F2)
        let comment = NSColor(hex: 0x6272A4)
        let cyan = NSColor(hex: 0x8BE9FD)
        let green = NSColor(hex: 0x50FA7B)
        let orange = NSColor(hex: 0xFFB86C)
        let pink = NSColor(hex: 0xFF79C6)
        let purple = NSColor(hex: 0xBD93F9)
        let red = NSColor(hex: 0xFF5555)

        let bodyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        let yellow = NSColor(hex: 0xF1FA8C)
        let highlighter = TreeSitterMarkdownHighlighter.Theme(
            bodyFont: bodyFont,
            bodyColor: foreground,
            dimColor: comment,
            headingColors: [1: purple, 2: purple, 3: purple, 4: purple, 5: purple, 6: purple],
            emphasisColor: yellow,
            strongColor: orange,
            codeColor: green,
            codeBackground: currentLine,
            linkColor: cyan,
            listMarkerColor: pink,
            codeColors: [
                "keyword": pink,
                "operator": pink,
                "string": yellow,
                "escape": pink,
                "comment": comment,
                "number": purple,
                "boolean": purple,
                "constant": purple,
                "function": green,
                "method": green,
                "constructor": green,
                "type": cyan,
                "attribute": green,
                "label": cyan,
                "variable": foreground,
                "property": foreground,
                "tag": pink,
            ]
        )

        let decorator = HybridUXDecorator.Style(
            dimColor: comment,
            revealColor: foreground,
            proximity: 2,
            headingWeight: .bold,
            bodyFont: bodyFont,
            blockquoteColor: cyan,
            horizontalRuleColor: comment,
            bodyColor: foreground
        )

        let wikilink = WikilinkDecorator.Style(
            resolvedColor: purple,
            unresolvedColor: red,
            bracketDimColor: comment,
            pillAlpha: 0.20,
            tagSaturation: 0.55,
            tagBrightness: 0.95
        )

        return EditorTheme(
            background: bg,
            foreground: foreground,
            insertionPoint: foreground,
            highlighterTheme: highlighter,
            decoratorStyle: decorator,
            wikilinkStyle: wikilink
        )
    }()
}

extension NSColor {
    /// Create an opaque sRGB color from a 0xRRGGBB hex value.
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
