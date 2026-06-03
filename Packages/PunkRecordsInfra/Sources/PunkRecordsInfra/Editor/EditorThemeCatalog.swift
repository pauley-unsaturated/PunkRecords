import AppKit
import Foundation

/// A named palette of the roles the editor colors. Mirrors the structure the
/// `.dracula` preset spells out by hand, so additional presets are just a
/// table of colors rather than a wall of sub-style wiring.
struct EditorThemePalette: Sendable {
    let background: NSColor
    let currentLine: NSColor
    let foreground: NSColor
    let comment: NSColor
    let cyan: NSColor
    let green: NSColor
    let orange: NSColor
    let pink: NSColor
    let purple: NSColor
    let red: NSColor
    let yellow: NSColor
}

extension EditorTheme {
    /// Builds a full `EditorTheme` from an 11-color palette using the same
    /// role assignment as the `.dracula` preset (headings→purple, emphasis→
    /// yellow, strong→orange, code→green, links→cyan, list markers→pink, …).
    /// Keeping one mapping means every preset stays visually consistent.
    static func make(
        from palette: EditorThemePalette,
        bodyFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    ) -> EditorTheme {
        let fg = palette.foreground
        let highlighter = TreeSitterMarkdownHighlighter.Theme(
            bodyFont: bodyFont,
            bodyColor: fg,
            dimColor: palette.comment,
            headingColors: [
                1: palette.purple, 2: palette.purple, 3: palette.purple,
                4: palette.purple, 5: palette.purple, 6: palette.purple,
            ],
            emphasisColor: palette.yellow,
            strongColor: palette.orange,
            codeColor: palette.green,
            codeBackground: palette.currentLine,
            linkColor: palette.cyan,
            listMarkerColor: palette.pink,
            codeColors: [
                "keyword": palette.pink,
                "operator": palette.pink,
                "string": palette.yellow,
                "escape": palette.pink,
                "comment": palette.comment,
                "number": palette.purple,
                "boolean": palette.purple,
                "constant": palette.purple,
                "function": palette.green,
                "method": palette.green,
                "constructor": palette.green,
                "type": palette.cyan,
                "attribute": palette.green,
                "label": palette.cyan,
                "variable": fg,
                "property": fg,
                "tag": palette.pink,
            ]
        )

        let decorator = HybridUXDecorator.Style(
            dimColor: palette.comment,
            revealColor: fg,
            proximity: 2,
            headingWeight: .bold,
            bodyFont: bodyFont,
            blockquoteColor: palette.cyan,
            horizontalRuleColor: palette.comment,
            bodyColor: fg
        )

        let wikilink = WikilinkDecorator.Style(
            resolvedColor: palette.purple,
            unresolvedColor: palette.red,
            bracketDimColor: palette.comment,
            pillAlpha: 0.20,
            tagSaturation: 0.55,
            tagBrightness: 0.95
        )

        return EditorTheme(
            background: palette.background,
            foreground: fg,
            insertionPoint: fg,
            highlighterTheme: highlighter,
            decoratorStyle: decorator,
            wikilinkStyle: wikilink
        )
    }

    // MARK: - Solarized (Ethan Schoonover)

    public static let solarizedDark = EditorTheme.make(from: EditorThemePalette(
        background: NSColor(hex: 0x002B36),
        currentLine: NSColor(hex: 0x073642),
        foreground: NSColor(hex: 0x839496),
        comment: NSColor(hex: 0x586E75),
        cyan: NSColor(hex: 0x2AA198),
        green: NSColor(hex: 0x859900),
        orange: NSColor(hex: 0xCB4B16),
        pink: NSColor(hex: 0xD33682),
        purple: NSColor(hex: 0x6C71C4),
        red: NSColor(hex: 0xDC322F),
        yellow: NSColor(hex: 0xB58900)
    ))

    public static let solarizedLight = EditorTheme.make(from: EditorThemePalette(
        background: NSColor(hex: 0xFDF6E3),
        currentLine: NSColor(hex: 0xEEE8D5),
        foreground: NSColor(hex: 0x657B83),
        comment: NSColor(hex: 0x93A1A1),
        cyan: NSColor(hex: 0x2AA198),
        green: NSColor(hex: 0x859900),
        orange: NSColor(hex: 0xCB4B16),
        pink: NSColor(hex: 0xD33682),
        purple: NSColor(hex: 0x6C71C4),
        red: NSColor(hex: 0xDC322F),
        yellow: NSColor(hex: 0xB58900)
    ))

    // MARK: - Nord (Arctic Ice Studio)

    public static let nord = EditorTheme.make(from: EditorThemePalette(
        background: NSColor(hex: 0x2E3440),   // nord0
        currentLine: NSColor(hex: 0x3B4252),  // nord1
        foreground: NSColor(hex: 0xD8DEE9),    // nord4
        comment: NSColor(hex: 0x4C566A),       // nord3
        cyan: NSColor(hex: 0x88C0D0),          // nord8
        green: NSColor(hex: 0xA3BE8C),         // nord14
        orange: NSColor(hex: 0xD08770),        // nord12
        pink: NSColor(hex: 0xB48EAD),          // nord15
        purple: NSColor(hex: 0x81A1C1),        // nord9
        red: NSColor(hex: 0xBF616A),           // nord11
        yellow: NSColor(hex: 0xEBCB8B)         // nord13
    ))
}

/// The set of editor themes the user can pick from, addressed by a stable
/// string id (persisted in `UserDefaults` as `editor.themeID`). Lives in Infra
/// alongside `EditorTheme` so the id↔theme mapping is unit-testable without the
/// SwiftUI layer.
public enum EditorThemeCatalog {
    public struct Entry: Sendable {
        public let id: String
        public let name: String
        public let theme: EditorTheme
    }

    /// The id used when none is stored, or when a stored id no longer resolves.
    /// Dracula keeps the editor's pre-picker default appearance.
    public static let defaultID = "dracula"

    /// All selectable themes, in display order.
    public static let all: [Entry] = [
        Entry(id: "default", name: "System Default", theme: .default),
        Entry(id: "dracula", name: "Dracula", theme: .dracula),
        Entry(id: "solarized-dark", name: "Solarized Dark", theme: .solarizedDark),
        Entry(id: "solarized-light", name: "Solarized Light", theme: .solarizedLight),
        Entry(id: "nord", name: "Nord", theme: .nord),
    ]

    /// The theme for a stored id, falling back to the default when the id is
    /// unknown (e.g. a preset removed in a later build).
    public static func theme(forID id: String) -> EditorTheme {
        entry(forID: id).theme
    }

    /// The display name for a stored id, falling back to the default's name.
    public static func displayName(forID id: String) -> String {
        entry(forID: id).name
    }

    private static func entry(forID id: String) -> Entry {
        all.first { $0.id == id }
            ?? all.first { $0.id == defaultID }
            ?? all[0]
    }
}
