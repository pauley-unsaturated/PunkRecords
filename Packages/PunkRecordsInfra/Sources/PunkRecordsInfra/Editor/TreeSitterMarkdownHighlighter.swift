import AppKit
import Foundation
import Neon
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import TreeSitterPython
import TreeSitterJavaScript

/// Live Markdown syntax highlighter backed by tree-sitter via Neon.
///
/// Wraps `Neon.TextViewHighlighter` so the rest of the app does not have to
/// know about Neon, SwiftTreeSitter, or the underlying grammars.
///
/// Attach one of these to an `NSTextView` once. Neon hooks into the text
/// view's `NSTextStorage` and re-styles incrementally as the user edits;
/// callers do not need to drive highlighting manually.
@MainActor
public final class TreeSitterMarkdownHighlighter {
    public struct Theme: @unchecked Sendable {
        public var bodyFont: NSFont
        public var bodyColor: NSColor
        public var dimColor: NSColor
        public var headingColors: [Int: NSColor]
        public var emphasisColor: NSColor
        public var strongColor: NSColor
        public var codeColor: NSColor
        public var codeBackground: NSColor
        public var linkColor: NSColor
        public var listMarkerColor: NSColor
        /// Colors for syntax-highlighted fenced code content, keyed by the
        /// leading component of a tree-sitter capture (e.g. "keyword", "string",
        /// "comment", "function", "type", "number"). Missing keys fall back to
        /// `codeColor`.
        public var codeColors: [String: NSColor]

        public init(
            bodyFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular),
            bodyColor: NSColor = .textColor,
            dimColor: NSColor = .tertiaryLabelColor,
            headingColors: [Int: NSColor] = [:],
            emphasisColor: NSColor = .labelColor,
            strongColor: NSColor = .labelColor,
            codeColor: NSColor = .systemPink,
            codeBackground: NSColor = .quaternaryLabelColor,
            linkColor: NSColor = .linkColor,
            listMarkerColor: NSColor = .systemYellow,
            codeColors: [String: NSColor] = [:]
        ) {
            self.bodyFont = bodyFont
            self.bodyColor = bodyColor
            self.dimColor = dimColor
            self.headingColors = headingColors
            self.emphasisColor = emphasisColor
            self.strongColor = strongColor
            self.codeColor = codeColor
            self.codeBackground = codeBackground
            self.linkColor = linkColor
            self.listMarkerColor = listMarkerColor
            self.codeColors = codeColors
        }

        public static let `default` = Theme()
    }

    public let theme: Theme

    private let highlighter: TextViewHighlighter

    public init(textView: NSTextView, theme: Theme = .default) throws {
        self.theme = theme

        let rootConfig = try Self.makeMarkdownConfiguration()
        let attributeProvider = Self.makeAttributeProvider(theme: theme)
        let languageProvider = Self.makeLanguageProvider()

        let configuration = TextViewHighlighter.Configuration(
            languageConfiguration: rootConfig,
            attributeProvider: attributeProvider,
            languageProvider: languageProvider,
            locationTransformer: { _ in nil }
        )

        self.highlighter = try TextViewHighlighter(
            textView: textView,
            configuration: configuration
        )
    }

    /// Force a re-highlight — e.g. after replacing the entire `textView.string`
    /// through a code path that does not go through editing notifications.
    public func invalidateAll() {
        highlighter.invalidate(.all)
    }

    // MARK: - Configuration helpers

    static func makeMarkdownConfiguration() throws -> LanguageConfiguration {
        let language = Language(language: tree_sitter_markdown())
        if let url = locateQueriesDirectory(named: "TreeSitterMarkdown_TreeSitterMarkdown") {
            return try LanguageConfiguration(language, name: "Markdown", queriesURL: url)
        }
        return try LanguageConfiguration(language, name: "Markdown")
    }

    static func makeInlineConfiguration() throws -> LanguageConfiguration {
        let language = Language(language: tree_sitter_markdown_inline())
        if let url = locateQueriesDirectory(named: "TreeSitterMarkdown_TreeSitterMarkdownInline") {
            return try LanguageConfiguration(language, name: "MarkdownInline", queriesURL: url)
        }
        return try LanguageConfiguration(language, name: "MarkdownInline")
    }

    /// Locate the queries directory inside a tree-sitter grammar's SPM resource bundle.
    ///
    /// SwiftTreeSitter's name-based discovery only searches `Bundle.main`, which works
    /// when running inside the app (Xcode embeds resource bundles into the .app) but
    /// fails under `swift test` where the test binary is loaded as a bundle by an
    /// out-of-tree helper (`swiftpm-testing-helper`). This fallback also looks next to
    /// the bundle that contains *this* class — which is the test bundle under
    /// `swift test`, and the app bundle in production.
    static func locateQueriesDirectory(named bundleName: String) -> URL? {
        let fileName = "\(bundleName).bundle"
        let candidateRoots: [URL] = {
            var roots: [URL] = []
            // 1. Bundle containing this code — sibling directory of the SPM resource bundle.
            let infraBundleURL = Bundle(for: TreeSitterMarkdownHighlighter.self).bundleURL
            roots.append(infraBundleURL.deletingLastPathComponent())
            roots.append(infraBundleURL.appendingPathComponent("Contents/Resources"))
            // 2. Bundle.main paths (production .app embedding).
            roots.append(Bundle.main.bundleURL)
            roots.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
            roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
            return roots
        }()

        let fm = FileManager.default
        for root in candidateRoots {
            let bundleURL = root.appendingPathComponent(fileName)
            guard fm.fileExists(atPath: bundleURL.path) else { continue }
            let shortPath = bundleURL.appendingPathComponent("queries")
            if fm.fileExists(atPath: shortPath.path) { return shortPath }
            let longPath = bundleURL.appendingPathComponent("Contents/Resources/queries")
            if fm.fileExists(atPath: longPath.path) { return longPath }
        }
        return nil
    }

    static func makeLanguageProvider() -> (String) -> LanguageConfiguration? {
        return { name in
            switch name.lowercased() {
            case "markdown_inline", "markdowninline", "inline":
                return try? Self.makeInlineConfiguration()
            case "swift":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_swift()),
                    name: "Swift",
                    bundleName: "TreeSitterSwift_TreeSitterSwift"
                )
            case "python", "py":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_python()),
                    name: "Python",
                    bundleName: "TreeSitterPython_TreeSitterPython"
                )
            case "javascript", "js":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_javascript()),
                    name: "JavaScript",
                    bundleName: "TreeSitterJavaScript_TreeSitterJavaScript"
                )
            default:
                return nil
            }
        }
    }

    /// Build a `LanguageConfiguration` for an injected code grammar, using the
    /// bundle-discovery fallback so queries are found under both the app and
    /// `swift test`.
    static func makeCodeConfiguration(
        language: Language,
        name: String,
        bundleName: String
    ) throws -> LanguageConfiguration {
        if let url = locateQueriesDirectory(named: bundleName) {
            return try LanguageConfiguration(language, name: name, queriesURL: url)
        }
        return try LanguageConfiguration(language, name: name)
    }

    static func makeAttributeProvider(theme: Theme) -> TokenAttributeProvider {
        return { token in
            Self.attributes(for: token.name, theme: theme)
        }
    }

    /// Pure mapping from a tree-sitter capture name to text attributes.
    /// Extracted so it can be unit-tested without instantiating an NSTextView.
    public static func attributes(
        for tokenName: String,
        theme: Theme = .default
    ) -> [NSAttributedString.Key: Any] {
        switch tokenName {
        case "text.title":
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .bold),
                .foregroundColor: theme.headingColors[1] ?? theme.bodyColor,
            ]
        case "text.strong":
            return [
                .font: NSFont.monospacedSystemFont(ofSize: theme.bodyFont.pointSize, weight: .bold),
                .foregroundColor: theme.strongColor,
            ]
        case "text.emphasis":
            let italic = NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask)
            return [
                .font: italic,
                .foregroundColor: theme.emphasisColor,
            ]
        case "text.literal":
            return [
                .foregroundColor: theme.codeColor,
                .backgroundColor: theme.codeBackground,
            ]
        case "text.uri":
            return [
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        case "text.reference":
            return [.foregroundColor: theme.linkColor]
        case "punctuation.special":
            return [.foregroundColor: theme.listMarkerColor]
        case "punctuation.delimiter":
            return [.foregroundColor: theme.dimColor]
        case "string.escape":
            return [.foregroundColor: theme.dimColor]
        case "none":
            // Code fence content — leave at body style, no extra attributes.
            return [:]
        default:
            // Injected-code captures (keyword, string, comment, function, …).
            // Match on the leading component so "keyword.function" maps like
            // "keyword". Falls back to codeColor for unmapped code captures.
            if let color = codeColor(for: tokenName, theme: theme) {
                return [.foregroundColor: color]
            }
            return [:]
        }
    }

    /// Resolve a fenced-code capture name to a color from the theme's code
    /// palette, or nil if it isn't a recognized code capture.
    static func codeColor(for tokenName: String, theme: Theme) -> NSColor? {
        let root = tokenName.split(separator: ".").first.map(String.init) ?? tokenName
        let codeRoots: Set<String> = [
            "keyword", "string", "comment", "number", "function", "method",
            "type", "constant", "variable", "operator", "property",
            "constructor", "attribute", "tag", "boolean", "escape", "label",
        ]
        guard codeRoots.contains(root) else { return nil }
        return theme.codeColors[root] ?? theme.codeColor
    }
}
