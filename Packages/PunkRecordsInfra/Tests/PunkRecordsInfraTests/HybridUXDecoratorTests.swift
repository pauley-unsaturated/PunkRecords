import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("HybridUXDecorator Tests")
struct HybridUXDecoratorTests {
    // MARK: - Marker proximity helper

    @Test("isNear returns true when caret is inside the range")
    func proximityInside() {
        let range = NSRange(location: 10, length: 4)
        #expect(HybridUXDecorator.isNear(range: range, location: 12, proximity: 2))
    }

    @Test("isNear returns true within proximity outside the range")
    func proximityWithinDistance() {
        let range = NSRange(location: 10, length: 4) // 10...14
        #expect(HybridUXDecorator.isNear(range: range, location: 8, proximity: 2))
        #expect(HybridUXDecorator.isNear(range: range, location: 16, proximity: 2))
    }

    @Test("isNear returns false beyond proximity")
    func proximityBeyond() {
        let range = NSRange(location: 10, length: 4)
        #expect(!HybridUXDecorator.isNear(range: range, location: 0, proximity: 2))
        #expect(!HybridUXDecorator.isNear(range: range, location: 100, proximity: 2))
    }

    // MARK: - Heading sizing

    @Test("Headings get per-level font sizes")
    func headingFontSizes() {
        let textView = NSTextView()
        textView.string = """
        # H1
        ## H2
        ### H3
        """
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let h1Font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let h2Font = storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        let h3Font = storage.attribute(.font, at: 11, effectiveRange: nil) as? NSFont

        #expect(h1Font?.pointSize == style.headingSizes[1])
        #expect(h2Font?.pointSize == style.headingSizes[2])
        #expect(h3Font?.pointSize == style.headingSizes[3])
    }

    @Test("Body paragraphs keep body font size")
    func bodyKeepsBodySize() {
        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.string = """
        # H1

        Just a body paragraph here.
        """
        let decorator = HybridUXDecorator()
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // Body paragraph starts after "# H1\n\n" — 6 chars in.
        let bodyFont = storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        // Body should keep its existing/inherited font, not get heading sizing.
        let h1Font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(bodyFont?.pointSize != h1Font?.pointSize)
    }

    // MARK: - Marker dimming

    @Test("Markers far from caret are dimmed")
    func farMarkersDimmed() {
        let textView = NSTextView()
        textView.string = "**bold** and *italic* and `code`"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // Look at the `*` markers for italic at position 13 — far from caret at 0.
        let italicMarkerColor = storage.attribute(.foregroundColor, at: 13, effectiveRange: nil) as? NSColor
        #expect(italicMarkerColor == style.dimColor)
    }

    @Test("Markers near caret are revealed at full contrast")
    func nearMarkersRevealed() {
        let textView = NSTextView()
        textView.string = "**bold** and *italic* and `code`"
        // Caret right next to the first ** marker.
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let nearMarkerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(nearMarkerColor == style.revealColor)
    }

    @Test("Caret position determines proximity per marker")
    func caretMovementRedimsCorrectly() {
        let textView = NSTextView()
        textView.string = "**a** and **b**"
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)

        // Caret at the second ** range (position 10 = inside "**b**").
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // First marker far → dim
        let firstMarker = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        // Second marker near → reveal
        let secondMarker = storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor

        #expect(firstMarker == style.dimColor)
        #expect(secondMarker == style.revealColor)
    }

    // MARK: - Blockquote / horizontal rule

    @Test("Blockquote line gets blockquote color")
    func blockquoteColored() {
        let textView = NSTextView()
        textView.string = "> a quote"
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // Position 3 is inside the quoted text (after "> a").
        let color = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(color == style.blockquoteColor)
    }

    @Test("Horizontal rule lines get HR color")
    func horizontalRuleColored() {
        let textView = NSTextView()
        textView.string = "---"
        let style = HybridUXDecorator.Style()
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == style.horizontalRuleColor)
    }

    // MARK: - Body color fill

    @Test("Text with no foreground (as Neon leaves it) gets the body color")
    func bodyColorFilled() {
        let textView = NSTextView()
        textView.string = "Plain paragraph with no markdown tokens."
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Simulate Neon resetting the range to default attributes that lack a
        // foreground color, which is what leaves body text illegible.
        textView.textStorage?.removeAttribute(
            .foregroundColor,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        let style = HybridUXDecorator.Style(bodyColor: .systemTeal)
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let color = storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemTeal)
    }

    @Test("Existing syntax colors are not overwritten by the body-color fill")
    func bodyColorPreservesExistingForeground() {
        let textView = NSTextView()
        textView.string = "token here"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Clear the auto-applied foreground, then color only "token" — as if a
        // tree-sitter token color landed on it and the rest stayed bare.
        textView.textStorage?.removeAttribute(
            .foregroundColor,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: NSColor.systemPink,
            range: NSRange(location: 0, length: 5)
        )
        let style = HybridUXDecorator.Style(bodyColor: .systemTeal)
        let decorator = HybridUXDecorator(style: style)
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let tokenColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bodyFillColor = storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor
        #expect(tokenColor == NSColor.systemPink, "existing token color must be preserved")
        #expect(bodyFillColor == NSColor.systemTeal, "uncolored text must get the body color")
    }

    // MARK: - Performance

    @Test("Decoration on a large document completes well under a frame budget")
    func performance() {
        // Build a synthetic 50KB markdown document with many markers.
        var lines: [String] = []
        for i in 0..<500 {
            lines.append("## Heading \(i)")
            lines.append("Paragraph with **bold** and *italic* and `code` and [link](https://example.com).")
            lines.append("- a bullet")
            lines.append("- another bullet")
            lines.append("> a quotation here")
            lines.append("")
        }
        let text = lines.joined(separator: "\n")

        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: text.count / 2, length: 0))
        let decorator = HybridUXDecorator()

        let start = ContinuousClock.now
        decorator.decorate(textView: textView)
        let elapsed = ContinuousClock.now - start
        // 16ms is one frame. Give plenty of headroom for CI variance.
        #expect(elapsed < .milliseconds(50), "Decoration took \(elapsed), expected < 50ms")
    }

    // MARK: - Idempotence

    @Test("Decoration is idempotent across repeated calls")
    func idempotent() {
        let textView = NSTextView()
        textView.string = "# Title\n\nSome **bold** text."
        let decorator = HybridUXDecorator()
        decorator.decorate(textView: textView)
        let snapshot1 = textView.textStorage!.copy() as! NSAttributedString

        decorator.decorate(textView: textView)
        let snapshot2 = textView.textStorage!.copy() as! NSAttributedString

        #expect(snapshot1.isEqual(to: snapshot2))
    }
}
