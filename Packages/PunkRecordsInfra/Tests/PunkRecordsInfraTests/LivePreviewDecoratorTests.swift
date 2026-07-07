import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("LivePreviewDecorator attribute application")
struct LivePreviewDecoratorTests {
    /// Off-screen text view: `EditorDecorationRange.scanRange` falls back to the
    /// full document, so the whole string is decorated.
    private func makeTextView(_ text: String, caret: Int) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    private func hasFold(_ textView: NSTextView, at index: Int) -> Bool {
        textView.textStorage?.attribute(.punkFolded, at: index, effectiveRange: nil) != nil
    }

    @Test("Folds land on markers when the caret is outside the element")
    func foldsApplied() {
        let textView = makeTextView("x **bold** y", caret: 0)
        let decorator = LivePreviewDecorator()
        decorator.decorate(textView: textView)
        #expect(hasFold(textView, at: 2))   // first * of the opening **
        #expect(hasFold(textView, at: 9))   // last * of the closing **
        #expect(!hasFold(textView, at: 5))  // content stays unfolded
    }

    @Test("Moving the caret inside the element unfolds it on the next pass")
    func caretEntryUnfolds() {
        let textView = makeTextView("x **bold** y", caret: 0)
        let decorator = LivePreviewDecorator()
        decorator.decorate(textView: textView)
        #expect(hasFold(textView, at: 2))

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        decorator.decorate(textView: textView)
        #expect(!hasFold(textView, at: 2))
        #expect(!hasFold(textView, at: 9))
    }

    @Test("The source string is never mutated by fold/unfold passes")
    func sourceUntouched() {
        let source = "# H\n**b** [t](http://x.co) [[W]] `c` ~~s~~"
        let textView = makeTextView(source, caret: 0)
        textView.allowsUndo = true
        let decorator = LivePreviewDecorator()

        decorator.decorate(textView: textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        decorator.decorate(textView: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        decorator.decorate(textView: textView)

        #expect(textView.string == source)
        // Attribute + glyph work registers nothing on the undo stack.
        #expect(textView.undoManager?.canUndo != true)
    }

    @Test("Disabling Live Preview unfolds everything on the next pass")
    func disableUnfoldsAll() {
        let textView = makeTextView("x **bold** y", caret: 0)
        let decorator = LivePreviewDecorator()
        decorator.decorate(textView: textView)
        #expect(hasFold(textView, at: 2))

        decorator.isEnabled = false
        decorator.decorate(textView: textView)
        #expect(!hasFold(textView, at: 2))
        #expect(!hasFold(textView, at: 9))
    }

    @Test("Link labels get link color + underline; markers fold")
    func linkLabelStyling() {
        let linkColor = NSColor.systemTeal
        let textView = makeTextView("see [text](http://x.co) end", caret: 26)
        let decorator = LivePreviewDecorator(style: .init(linkColor: linkColor))
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        #expect(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor == linkColor)
        #expect(storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) != nil)
        #expect(hasFold(textView, at: 4))   // [
        #expect(hasFold(textView, at: 9))   // ]
        #expect(hasFold(textView, at: 15))  // inside the url
        #expect(hasFold(textView, at: 22))  // )
        #expect(!hasFold(textView, at: 6))  // label stays visible
    }

    @Test("Disabling Live Preview strips link underline styling")
    func disableStripsLinkStyling() {
        let textView = makeTextView("see [text](http://x.co) end", caret: 26)
        let decorator = LivePreviewDecorator()
        decorator.decorate(textView: textView)
        let storage = textView.textStorage!
        #expect(storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) != nil)

        decorator.isEnabled = false
        decorator.decorate(textView: textView)
        #expect(storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) == nil)
    }

    @Test("Wikilink bracket folding composes with the pill decoration")
    func wikilinkPillComposition() {
        // Caret far from "[[Note]]": WikilinkDecorator draws the pill on the
        // inner text while LivePreviewDecorator folds the brackets.
        let textView = makeTextView("a [[Note]] b", caret: 0)
        let wikilink = WikilinkDecorator(isResolved: { _ in true })
        let livePreview = LivePreviewDecorator()
        wikilink.decorate(textView: textView)
        livePreview.decorate(textView: textView)

        let storage = textView.textStorage!
        #expect(storage.attribute(.pillBackground, at: 5, effectiveRange: nil) != nil) // inner
        #expect(hasFold(textView, at: 2))  // [[
        #expect(hasFold(textView, at: 8))  // ]]
        #expect(!hasFold(textView, at: 5)) // inner stays visible

        // Caret inside: pill removed by WikilinkDecorator, brackets unfolded.
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        wikilink.decorate(textView: textView)
        livePreview.decorate(textView: textView)
        #expect(storage.attribute(.pillBackground, at: 5, effectiveRange: nil) == nil)
        #expect(!hasFold(textView, at: 2))
        #expect(!hasFold(textView, at: 8))
    }

    @Test("Heading hash prefix folds; the title keeps its glyphs")
    func headingFoldAttribute() {
        let textView = makeTextView("# Title\nbody", caret: 10)
        let decorator = LivePreviewDecorator()
        decorator.decorate(textView: textView)
        #expect(hasFold(textView, at: 0))   // #
        #expect(hasFold(textView, at: 1))   // the single trailing space
        #expect(!hasFold(textView, at: 2))  // T
    }
}
