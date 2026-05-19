import AppKit
import Foundation

/// Hybrid-markdown decoration overlay applied on top of `TreeSitterMarkdownHighlighter`.
///
/// Tree-sitter handles tokenization and per-token coloring; this layer adds the
/// "Bear / iA Writer feel" — markers visually recede when the caret is far,
/// reveal at full contrast when the caret approaches, and headings render at
/// scaled font sizes.
///
/// Call `decorate(textView:)` whenever the selection or text changes. The
/// decoration pass runs in a `beginEditing`/`endEditing` block so AppKit
/// coalesces re-layout.
@MainActor
public final class HybridUXDecorator {
    public struct Style: @unchecked Sendable {
        /// Color applied to markers that are far from the caret.
        public var dimColor: NSColor
        /// Color applied to markers within `proximity` of the caret.
        public var revealColor: NSColor
        /// Character distance from the caret within which markers reveal.
        public var proximity: Int
        /// Font sizes per heading level (1...6). Missing levels fall back to body size.
        public var headingSizes: [Int: CGFloat]
        /// Bold weight applied to heading text.
        public var headingWeight: NSFont.Weight
        /// Body font — used as the basis for heading size scaling.
        public var bodyFont: NSFont
        /// Foreground color for blockquote lines.
        public var blockquoteColor: NSColor
        /// Foreground color for horizontal rule lines.
        public var horizontalRuleColor: NSColor

        public init(
            dimColor: NSColor = .tertiaryLabelColor,
            revealColor: NSColor = .labelColor,
            proximity: Int = 2,
            headingSizes: [Int: CGFloat] = [
                1: 24,
                2: 20,
                3: 17,
                4: 15,
                5: 14,
                6: 13,
            ],
            headingWeight: NSFont.Weight = .bold,
            bodyFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular),
            blockquoteColor: NSColor = .systemMint,
            horizontalRuleColor: NSColor = .separatorColor
        ) {
            self.dimColor = dimColor
            self.revealColor = revealColor
            self.proximity = proximity
            self.headingSizes = headingSizes
            self.headingWeight = headingWeight
            self.bodyFont = bodyFont
            self.blockquoteColor = blockquoteColor
            self.horizontalRuleColor = horizontalRuleColor
        }

        public static let `default` = Style()
    }

    public let style: Style

    public init(style: Style = .default) {
        self.style = style
    }

    /// Apply hybrid-markdown decorations to the text view based on its current
    /// content and caret position. Safe to call repeatedly.
    public func decorate(textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let text = textView.string as NSString
        let fullLength = text.length
        guard fullLength > 0 else { return }

        let caretLocation = textView.selectedRange().location
        let proximity = style.proximity

        textStorage.beginEditing()

        applyHeadingSizes(to: textStorage, text: text)
        applyBlockquoteStyling(to: textStorage, text: text)
        applyHorizontalRuleStyling(to: textStorage, text: text)
        applyMarkerDimming(
            to: textStorage,
            text: text,
            caretLocation: caretLocation,
            proximity: proximity
        )

        textStorage.endEditing()
    }

    // MARK: - Heading sizing

    private static let headingRegex: NSRegularExpression = {
        // Matches: optional up-to-3 leading spaces, 1-6 #s, space, then the rest of the line.
        try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})\s+(.*)$"#, options: [.anchorsMatchLines])
    }()

    private func applyHeadingSizes(to textStorage: NSTextStorage, text: NSString) {
        let fullRange = NSRange(location: 0, length: text.length)
        Self.headingRegex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            let hashRange = match.range(at: 2)
            let level = hashRange.length
            let size = style.headingSizes[level] ?? style.bodyFont.pointSize
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: style.headingWeight)
            // Apply font to the entire heading line so markers + text scale together.
            textStorage.addAttribute(.font, value: font, range: match.range)
        }
    }

    // MARK: - Blockquote / horizontal rule styling

    private static let blockquoteRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^( {0,3}>+\s?.*)$"#, options: [.anchorsMatchLines])
    }()

    private func applyBlockquoteStyling(to textStorage: NSTextStorage, text: NSString) {
        let fullRange = NSRange(location: 0, length: text.length)
        Self.blockquoteRegex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            textStorage.addAttribute(.foregroundColor, value: style.blockquoteColor, range: match.range)
        }
    }

    private static let horizontalRuleRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^( {0,3})([-*_])(\s*\2){2,}\s*$"#, options: [.anchorsMatchLines])
    }()

    private func applyHorizontalRuleStyling(to textStorage: NSTextStorage, text: NSString) {
        let fullRange = NSRange(location: 0, length: text.length)
        Self.horizontalRuleRegex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            textStorage.addAttribute(.foregroundColor, value: style.horizontalRuleColor, range: match.range)
        }
    }

    // MARK: - Marker dimming

    /// Markdown markers we apply caret-proximity dimming to.
    private static let markerRegexes: [NSRegularExpression] = {
        let patterns: [String] = [
            #"^( {0,3}#{1,6})\s"#,           // ATX heading markers
            #"\*\*"#,                          // bold asterisk
            #"__"#,                            // bold underscore
            #"(?<!\*)\*(?!\*)"#,             // italic single asterisk
            #"(?<!_)_(?!_)"#,                 // italic single underscore
            #"~~"#,                            // strikethrough
            #"`"#,                             // inline code backticks (also fences)
            #"^( {0,3}>+ ?)"#,                // blockquote marker
            #"^( {0,3})([-*+])\s"#,           // list bullet
            #"^( {0,3})(\d+\.)\s"#,           // ordered list marker
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }()

    private func applyMarkerDimming(
        to textStorage: NSTextStorage,
        text: NSString,
        caretLocation: Int,
        proximity: Int
    ) {
        let fullRange = NSRange(location: 0, length: text.length)
        for regex in Self.markerRegexes {
            regex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
                guard let match else { return }
                let markerRange = match.range
                let color = HybridUXDecorator.isNear(
                    range: markerRange,
                    location: caretLocation,
                    proximity: proximity
                )
                    ? style.revealColor
                    : style.dimColor
                textStorage.addAttribute(.foregroundColor, value: color, range: markerRange)
            }
        }
    }

    /// True if `location` is within `proximity` characters of `range` (inclusive).
    public static func isNear(range: NSRange, location: Int, proximity: Int) -> Bool {
        let lower = range.location
        let upper = range.location + range.length
        if location >= lower - proximity && location <= upper + proximity {
            return true
        }
        return false
    }
}
