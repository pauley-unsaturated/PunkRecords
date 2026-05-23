import AppKit
import Foundation

/// Renders `[[wikilink]]` and `#tag` ranges as pill chips on top of the
/// tree-sitter highlighting and hybrid-UX decoration.
///
/// Pills appear when the caret is outside the range; when the caret enters,
/// the raw source is restored at full contrast so the user can edit it.
/// The underlying text is never mutated — pills are drawn by
/// `WikilinkPillLayoutManager` from the `.pillBackground` attribute, so the
/// document string stays editable and searchable.
@MainActor
public final class WikilinkDecorator {
    public struct Style: @unchecked Sendable {
        public var resolvedColor: NSColor
        public var unresolvedColor: NSColor
        public var bracketDimColor: NSColor
        public var pillAlpha: CGFloat
        public var tagSaturation: CGFloat
        public var tagBrightness: CGFloat

        public init(
            resolvedColor: NSColor = .linkColor,
            unresolvedColor: NSColor = .systemRed,
            bracketDimColor: NSColor = .tertiaryLabelColor,
            pillAlpha: CGFloat = 0.16,
            tagSaturation: CGFloat = 0.55,
            tagBrightness: CGFloat = 0.85
        ) {
            self.resolvedColor = resolvedColor
            self.unresolvedColor = unresolvedColor
            self.bracketDimColor = bracketDimColor
            self.pillAlpha = pillAlpha
            self.tagSaturation = tagSaturation
            self.tagBrightness = tagBrightness
        }

        public static let `default` = Style()
    }

    public let style: Style
    /// Returns true if a wikilink target resolves to an existing note.
    private let isResolved: (String) -> Bool

    public init(style: Style = .default, isResolved: @escaping (String) -> Bool) {
        self.style = style
        self.isResolved = isResolved
    }

    // MARK: - Regex

    static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
    static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/])#([A-Za-z][A-Za-z0-9_/-]*)"#
    )

    // MARK: - Decoration

    public func decorate(textView: NSTextView) {
        decorate(textView: textView, in: EditorDecorationRange.scanRange(for: textView))
    }

    /// Decorate only `scanRange` — limits per-keystroke work to the visible region.
    public func decorate(textView: NSTextView, in scanRange: NSRange) {
        guard let textStorage = textView.textStorage else { return }
        let text = textView.string as NSString
        guard text.length > 0, scanRange.length > 0 else { return }
        let caret = textView.selectedRange().location

        textStorage.beginEditing()
        decorateWikilinks(in: textStorage, text: text, scanRange: scanRange, caret: caret)
        decorateTags(in: textStorage, text: text, scanRange: scanRange, caret: caret)
        textStorage.endEditing()
    }

    private func decorateWikilinks(in storage: NSTextStorage, text: NSString, scanRange: NSRange, caret: Int) {
        Self.wikilinkRegex.enumerateMatches(in: text as String, range: scanRange) { match, _, _ in
            guard let match else { return }
            let whole = match.range
            let inner = match.range(at: 1)
            let target = Self.target(fromInner: text.substring(with: inner))
            let caretInside = caret >= whole.location && caret <= whole.location + whole.length

            // Brackets: first 2 and last 2 chars of the whole range.
            let openBrackets = NSRange(location: whole.location, length: 2)
            let closeBrackets = NSRange(location: whole.location + whole.length - 2, length: 2)

            if caretInside {
                // Reveal source — clear any pill, normalize bracket contrast.
                storage.removeAttribute(.pillBackground, range: whole)
                storage.addAttribute(.foregroundColor, value: style.bracketDimColor, range: openBrackets)
                storage.addAttribute(.foregroundColor, value: style.bracketDimColor, range: closeBrackets)
            } else {
                let resolved = isResolved(target)
                let color = resolved ? style.resolvedColor : style.unresolvedColor
                storage.addAttribute(.foregroundColor, value: color, range: inner)
                storage.addAttribute(
                    .pillBackground,
                    value: color.withAlphaComponent(style.pillAlpha),
                    range: inner
                )
                if !resolved {
                    storage.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                        range: inner
                    )
                }
                storage.addAttribute(.foregroundColor, value: style.bracketDimColor, range: openBrackets)
                storage.addAttribute(.foregroundColor, value: style.bracketDimColor, range: closeBrackets)
            }
        }
    }

    private func decorateTags(in storage: NSTextStorage, text: NSString, scanRange: NSRange, caret: Int) {
        Self.tagRegex.enumerateMatches(in: text as String, range: scanRange) { match, _, _ in
            guard let match else { return }
            let whole = match.range
            let name = text.substring(with: match.range(at: 1))
            let caretInside = caret >= whole.location && caret <= whole.location + whole.length
            let color = Self.tagColor(
                for: name,
                saturation: style.tagSaturation,
                brightness: style.tagBrightness
            )
            if caretInside {
                storage.removeAttribute(.pillBackground, range: whole)
                storage.addAttribute(.foregroundColor, value: color, range: whole)
            } else {
                storage.addAttribute(.foregroundColor, value: color, range: whole)
                storage.addAttribute(
                    .pillBackground,
                    value: color.withAlphaComponent(style.pillAlpha),
                    range: whole
                )
            }
        }
    }

    // MARK: - Hit testing (click-to-open)

    /// Returns the wikilink target whose pill encloses `charIndex`, or nil.
    /// Brackets are excluded — only a click on the link label opens the note.
    public func wikilinkTarget(at charIndex: Int, in text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: String?
        Self.wikilinkRegex.enumerateMatches(in: text, range: full) { match, _, stop in
            guard let match else { return }
            let inner = match.range(at: 1)
            if charIndex >= inner.location && charIndex < inner.location + inner.length {
                result = Self.target(fromInner: ns.substring(with: inner))
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: - Helpers

    /// `Foo|alias` -> `Foo`; trims whitespace.
    static func target(fromInner inner: String) -> String {
        let target = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
        return target.trimmingCharacters(in: .whitespaces)
    }

    /// Stable hue derived from the tag name so a given tag is always the same color.
    static func tagColor(for name: String, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }
}
