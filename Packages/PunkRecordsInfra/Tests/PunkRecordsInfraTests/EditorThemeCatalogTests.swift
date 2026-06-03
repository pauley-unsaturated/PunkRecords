import AppKit
import Foundation
import Testing
@testable import PunkRecordsInfra

@MainActor
@Suite("EditorThemeCatalog Tests")
struct EditorThemeCatalogTests {
    private func sRGB(_ hex: UInt32) -> NSColor { NSColor(hex: hex).usingColorSpace(.sRGB)! }

    @Test("Catalog ids are unique")
    func idsUnique() {
        let ids = EditorThemeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Catalog includes the built-in presets plus the new ones")
    func catalogMembership() {
        let ids = Set(EditorThemeCatalog.all.map(\.id))
        #expect(ids == ["default", "dracula", "solarized-dark", "solarized-light", "nord"])
    }

    @Test("Default id resolves and matches the pre-picker default (Dracula)")
    func defaultID() {
        #expect(EditorThemeCatalog.defaultID == "dracula")
        let resolved = EditorThemeCatalog.theme(forID: EditorThemeCatalog.defaultID).background.usingColorSpace(.sRGB)!
        #expect(resolved == sRGB(0x282A36))
    }

    @Test("Unknown id falls back to the default theme and name")
    func unknownIDFallsBack() {
        let fallbackBG = EditorThemeCatalog.theme(forID: "no-such-theme").background.usingColorSpace(.sRGB)!
        #expect(fallbackBG == sRGB(0x282A36)) // Dracula
        #expect(EditorThemeCatalog.displayName(forID: "no-such-theme") == "Dracula")
    }

    @Test("theme(forID:) returns the requested preset")
    func resolvesByID() {
        #expect(EditorThemeCatalog.theme(forID: "nord").background.usingColorSpace(.sRGB)! == sRGB(0x2E3440))
        #expect(EditorThemeCatalog.theme(forID: "solarized-dark").background.usingColorSpace(.sRGB)! == sRGB(0x002B36))
        #expect(EditorThemeCatalog.theme(forID: "solarized-light").background.usingColorSpace(.sRGB)! == sRGB(0xFDF6E3))
    }

    @Test("displayName(forID:) returns the human label")
    func displayNames() {
        #expect(EditorThemeCatalog.displayName(forID: "nord") == "Nord")
        #expect(EditorThemeCatalog.displayName(forID: "solarized-light") == "Solarized Light")
    }

    @Test("make(from:) wires the palette into consistent sub-styles")
    func paletteMappingIsConsistent() {
        let nord = EditorThemeCatalog.theme(forID: "nord")
        // Body color flows into both the decorator fill and highlighter body.
        #expect(nord.decoratorStyle.bodyColor == nord.foreground)
        #expect(nord.highlighterTheme.bodyColor == nord.foreground)
        // Foreground is nord4 (#D8DEE9); insertion point matches foreground.
        #expect(nord.foreground.usingColorSpace(.sRGB)! == sRGB(0xD8DEE9))
        #expect(nord.insertionPoint == nord.foreground)
        // Resolved vs unresolved wikilinks are distinct.
        #expect(nord.wikilinkStyle.resolvedColor != nord.wikilinkStyle.unresolvedColor)
        // Headings present for all six levels.
        #expect((1...6).allSatisfy { nord.highlighterTheme.headingColors[$0] != nil })
    }

    @Test("Solarized light uses a light background; dark uses a dark one")
    func solarizedContrast() {
        func luma(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB)!
            return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        }
        let light = EditorThemeCatalog.theme(forID: "solarized-light").background
        let dark = EditorThemeCatalog.theme(forID: "solarized-dark").background
        #expect(luma(light) > luma(dark))
    }
}
