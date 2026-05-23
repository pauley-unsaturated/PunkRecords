import AppKit
import Foundation

public extension NSAttributedString.Key {
    /// Value: `NSColor` — the fill color of a rounded pill drawn behind this range.
    /// Set by `WikilinkDecorator` on `[[wikilink]]` and `#tag` ranges when the
    /// caret is outside them.
    static let pillBackground = NSAttributedString.Key("PunkRecordsPillBackground")
}

/// TextKit 1 layout manager that draws rounded "pill" backgrounds behind any
/// range carrying the `.pillBackground` attribute. Used for wikilink and tag
/// chips. The underlying source text is left intact (no attachment swapping),
/// so the document string stays editable and searchable.
public final class WikilinkPillLayoutManager: NSLayoutManager {
    /// Corner radius of the pill, in points.
    public var pillCornerRadius: CGFloat = 4
    /// Horizontal inset (negative = padding) applied to each enclosing rect.
    public var pillHorizontalPadding: CGFloat = 2

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
