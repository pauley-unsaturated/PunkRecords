import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("EditorTheme Tests")
struct EditorThemeTests {
    @Test("Hex initializer decodes RRGGBB components")
    func hexInit() {
        let color = NSColor(hex: 0x282A36).usingColorSpace(.sRGB)!
        #expect(Int((color.redComponent * 255).rounded()) == 0x28)
        #expect(Int((color.greenComponent * 255).rounded()) == 0x2A)
        #expect(Int((color.blueComponent * 255).rounded()) == 0x36)
        #expect(color.alphaComponent == 1.0)
    }

    @Test("Dracula background is the canonical #282A36")
    func draculaBackground() {
        let bg = EditorTheme.dracula.background.usingColorSpace(.sRGB)!
        let expected = NSColor(hex: 0x282A36).usingColorSpace(.sRGB)!
        #expect(bg == expected)
    }

    @Test("Dracula foreground is light for dark-background legibility")
    func draculaForeground() {
        let fg = EditorTheme.dracula.foreground.usingColorSpace(.sRGB)!
        // #F8F8F2 — near-white.
        #expect(fg.redComponent > 0.9)
        #expect(fg.greenComponent > 0.9)
        #expect(fg.blueComponent > 0.9)
    }

    @Test("Dracula maps the sub-styles to its own palette")
    func draculaSubStyles() {
        let theme = EditorTheme.dracula
        // Body color flows into the decorator's fill + highlighter body.
        #expect(theme.decoratorStyle.bodyColor == theme.foreground)
        #expect(theme.highlighterTheme.bodyColor == theme.foreground)
        // Headings are purple, code is green, strong is orange — all distinct.
        let heading = theme.highlighterTheme.headingColors[1]
        #expect(heading != nil)
        #expect(heading != theme.highlighterTheme.codeColor)
        #expect(theme.highlighterTheme.strongColor != theme.highlighterTheme.emphasisColor)
        // Unresolved wikilinks are red, distinct from resolved.
        #expect(theme.wikilinkStyle.resolvedColor != theme.wikilinkStyle.unresolvedColor)
    }

    @Test("Default theme uses adaptive system colors")
    func defaultTheme() {
        #expect(EditorTheme.default.background == NSColor.textBackgroundColor)
        #expect(EditorTheme.default.foreground == NSColor.textColor)
    }
}
