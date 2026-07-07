import AppKit
import Foundation

public extension NSAttributedString.Key {
    /// Value: `NSColor` — the fill color of a rounded pill drawn behind this range.
    /// Set by `WikilinkDecorator` on `[[wikilink]]` and `#tag` ranges when the
    /// caret is outside them.
    static let pillBackground = NSAttributedString.Key("PunkRecordsPillBackground")

    /// Value: any non-nil marker (e.g. `true`) — the character should render at
    /// zero width (a null glyph). Set by `LivePreviewDecorator` on markdown
    /// marker characters (`**`, `` ` ``, `# `, …) whose element the caret is
    /// outside, so the marker visually recedes without ever mutating the source.
    /// Read by `WikilinkPillLayoutManager`'s glyph-generation delegate hook.
    static let punkFolded = NSAttributedString.Key("PunkRecordsFolded")
}

/// TextKit 1 layout manager that draws rounded "pill" backgrounds behind any
/// range carrying the `.pillBackground` attribute (wikilink and tag chips) and
/// folds any range carrying the `.punkFolded` attribute to zero width by
/// generating null glyphs for it.
///
/// The underlying source text is left intact in both cases (no attachment
/// swapping, no `replaceCharacters`), so the document string stays editable and
/// searchable and the undo stack is untouched.
public final class WikilinkPillLayoutManager: NSLayoutManager {
    /// Corner radius of the pill, in points.
    public var pillCornerRadius: CGFloat = 4
    /// Horizontal inset (negative = padding) applied to each enclosing rect.
    public var pillHorizontalPadding: CGFloat = 2

    public override init() {
        super.init()
        // Be our own glyph-generation delegate so `.punkFolded` characters fold
        // to null glyphs. `delegate` is weak, so this is not a retain cycle.
        delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        textStorage.enumerateAttribute(.pillBackground, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            self.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let drawRect = rect
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -self.pillHorizontalPadding, dy: 0.5)
                let path = NSBezierPath(
                    roundedRect: drawRect,
                    xRadius: self.pillCornerRadius,
                    yRadius: self.pillCornerRadius
                )
                color.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Glyph folding

extension WikilinkPillLayoutManager: NSLayoutManagerDelegate {
    /// Fold characters carrying `.punkFolded` to zero width by marking their
    /// glyphs `.null` (no advancement, not drawn). Characters without the
    /// attribute are left to the layout manager's default generation.
    ///
    /// Returning a non-zero value tells the layout manager we handled glyph
    /// generation for the whole range; returning 0 falls back to default
    /// generation. We therefore only take over when the range actually contains
    /// folded characters, so unfolded text pays no cost.
    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let textStorage = layoutManager.textStorage else { return 0 }
        let length = glyphRange.length
        guard length > 0 else { return 0 }

        let storageLength = textStorage.length
        var foldedGlyphIndexes: [Int] = []
        for glyphIndex in 0..<length {
            let charIndex = charIndexes[glyphIndex]
            guard charIndex < storageLength else { continue }
            if textStorage.attribute(.punkFolded, at: charIndex, effectiveRange: nil) != nil {
                foldedGlyphIndexes.append(glyphIndex)
            }
        }
        guard !foldedGlyphIndexes.isEmpty else { return 0 }

        var newProperties = Array(UnsafeBufferPointer(start: props, count: length))
        for glyphIndex in foldedGlyphIndexes {
            newProperties[glyphIndex] = .null
        }
        newProperties.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            layoutManager.setGlyphs(
                glyphs,
                properties: base,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
        return length
    }
}
