import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("WikilinkDecorator Tests")
struct WikilinkDecoratorTests {
    // MARK: - Target parsing

    @Test("Plain target parses verbatim")
    func plainTarget() {
        #expect(WikilinkDecorator.target(fromInner: "Foo Note") == "Foo Note")
    }

    @Test("Aliased target keeps only the target half")
    func aliasedTarget() {
        #expect(WikilinkDecorator.target(fromInner: "Foo Note|the alias") == "Foo Note")
    }

    @Test("Target is whitespace-trimmed")
    func trimmedTarget() {
        #expect(WikilinkDecorator.target(fromInner: "  Spacey  ") == "Spacey")
    }

    // MARK: - Tag color stability

    @Test("Tag color is stable for the same tag")
    func tagColorStable() {
        let a = WikilinkDecorator.tagColor(for: "swift", saturation: 0.5, brightness: 0.8)
        let b = WikilinkDecorator.tagColor(for: "swift", saturation: 0.5, brightness: 0.8)
        #expect(a == b)
    }

    @Test("Tag color is case-insensitive")
    func tagColorCaseInsensitive() {
        let a = WikilinkDecorator.tagColor(for: "Swift", saturation: 0.5, brightness: 0.8)
        let b = WikilinkDecorator.tagColor(for: "swift", saturation: 0.5, brightness: 0.8)
        #expect(a == b)
    }

    @Test("Different tags usually get different colors")
    func tagColorDiffers() {
        let a = WikilinkDecorator.tagColor(for: "swift", saturation: 0.5, brightness: 0.8)
        let b = WikilinkDecorator.tagColor(for: "python", saturation: 0.5, brightness: 0.8)
        #expect(a != b)
    }

    // MARK: - Hit testing

    @Test("Hit test returns target when index is inside the link label")
    func hitInsideLabel() {
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        let text = "see [[Foo Note]] here"
        // "[[Foo Note]]" starts at 4; inner "Foo Note" at 6..<14.
        #expect(decorator.wikilinkTarget(at: 8, in: text) == "Foo Note")
    }

    @Test("Hit test returns nil on the brackets")
    func hitOnBrackets() {
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        let text = "see [[Foo Note]] here"
        // Bracket positions 4,5 (open) — outside the inner label.
        #expect(decorator.wikilinkTarget(at: 4, in: text) == nil)
    }

    @Test("Hit test returns nil outside any link")
    func hitOutside() {
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        let text = "see [[Foo Note]] here"
        #expect(decorator.wikilinkTarget(at: 0, in: text) == nil)
    }

    @Test("Hit test resolves alias links to the target")
    func hitAlias() {
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        let text = "[[Target|Alias]]"
        // Inner "Target|Alias" at 2..<14.
        #expect(decorator.wikilinkTarget(at: 5, in: text) == "Target")
    }

    // MARK: - Decoration application

    @Test("Resolved link gets pill background when caret is outside")
    func resolvedPill() {
        let textView = NSTextView()
        textView.string = "see [[Foo]] here"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // Inner "Foo" at 6..<9.
        let pill = storage.attribute(.pillBackground, at: 7, effectiveRange: nil)
        #expect(pill != nil)
    }

    @Test("Caret inside a link removes the pill (reveals source)")
    func caretInsideRevealsSource() {
        let textView = NSTextView()
        textView.string = "see [[Foo]] here"
        // Caret inside the link (position 7, inside "Foo").
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let pill = storage.attribute(.pillBackground, at: 7, effectiveRange: nil)
        #expect(pill == nil)
    }

    @Test("Unresolved link gets a dashed underline")
    func unresolvedUnderline() {
        let textView = NSTextView()
        textView.string = "see [[Ghost]] here"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let decorator = WikilinkDecorator(isResolved: { _ in false })
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // Inner "Ghost" at 6..<11.
        let underline = storage.attribute(.underlineStyle, at: 7, effectiveRange: nil) as? Int
        #expect(underline != nil)
    }

    @Test("Tags get a pill background")
    func tagPill() {
        let textView = NSTextView()
        textView.string = "tagged #swift here"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        // "#swift" starts at 7.
        let pill = storage.attribute(.pillBackground, at: 8, effectiveRange: nil)
        #expect(pill != nil)
    }

    @Test("Heading hashes are not treated as tags")
    func headingNotTag() {
        let textView = NSTextView()
        textView.string = "# Heading"
        textView.setSelectedRange(NSRange(location: 50, length: 0))
        let decorator = WikilinkDecorator(isResolved: { _ in true })
        decorator.decorate(textView: textView)

        let storage = textView.textStorage!
        let pill = storage.attribute(.pillBackground, at: 0, effectiveRange: nil)
        #expect(pill == nil)
    }
}
