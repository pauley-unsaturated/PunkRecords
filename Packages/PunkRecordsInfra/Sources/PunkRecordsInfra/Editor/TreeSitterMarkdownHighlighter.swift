import AppKit
import Foundation
import Neon
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import TreeSitterPython
import TreeSitterJavaScript
import TreeSitterRust
import TreeSitterC
import TreeSitterCPP
import TreeSitterTypeScript

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
            case "javascript", "js", "jsx", "mjs", "cjs":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_javascript()),
                    name: "JavaScript",
                    bundleName: "TreeSitterJavaScript_TreeSitterJavaScript"
                )
            case "typescript", "ts", "mts", "cts":
                // TypeScript's highlights.scm carries only TS-specific rules and
                // inherits the rest from JavaScript, so concatenate both.
                return try? Self.makeInheritedCodeConfiguration(
                    language: Language(language: tree_sitter_typescript()),
                    name: "TypeScript",
                    childBundle: "TreeSitterTypeScript_TreeSitterTypeScript",
                    parentBundle: "TreeSitterJavaScript_TreeSitterJavaScript"
                )
            case "rust", "rs":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_rust()),
                    name: "Rust",
                    bundleName: "TreeSitterRust_TreeSitterRust"
                )
            case "c", "h":
                return try? Self.makeCodeConfiguration(
                    language: Language(language: tree_sitter_c()),
                    name: "C",
                    bundleName: "TreeSitterC_TreeSitterC"
                )
            case "cpp", "c++", "cc", "cxx", "hpp", "hxx", "h++", "hh":
                // C++ inherits its base highlights from C (comments, numbers,
                // plain strings, preprocessor); concatenate both queries.
                return try? Self.makeInheritedCodeConfiguration(
                    language: Language(language: tree_sitter_cpp()),
                    name: "C++",
                    childBundle: "TreeSitterCPP_TreeSitterCPP",
                    parentBundle: "TreeSitterC_TreeSitterC"
                )
            default:
                return nil
            }
        }
    }

    /// Build a configuration for a grammar whose `highlights.scm` only carries
    /// rules layered on top of a parent grammar (e.g. TypeScript over
    /// JavaScript, C++ over C). The official tree-sitter repos keep these
    /// queries split and rely on the nvim-treesitter `inherits` convention,
    /// which SwiftTreeSitter does not implement — so we concatenate the parent
    /// and child highlight queries ourselves (parent first, child appended so
    /// its patterns win) and compile them against the child language.
    ///
    /// Compiling the parent query against the child grammar is safe because the
    /// child grammar is a superset of the parent's node types. If the combined
    /// query fails to compile for any reason, falls back to the child's own
    /// queries so highlighting degrades gracefully instead of vanishing.
    static func makeInheritedCodeConfiguration(
        language: Language,
        name: String,
        childBundle: String,
        parentBundle: String
    ) throws -> LanguageConfiguration {
        guard let childURL = locateQueriesDirectory(named: childBundle) else {
            return try makeCodeConfiguration(language: language, name: name, bundleName: childBundle)
        }

        func read(_ url: URL?, _ file: String) -> String {
            guard let url else { return "" }
            return (try? String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)) ?? ""
        }

        let parentURL = locateQueriesDirectory(named: parentBundle)
        let combined = read(parentURL, "highlights.scm") + "\n" + read(childURL, "highlights.scm")

        var queries: [Query.Definition: Query] = [:]
        if let data = combined.data(using: .utf8), let query = try? Query(language: language, data: data) {
            queries[.highlights] = query
        }
        // Injections / locals come from the child grammar only.
        if let data = try? Data(contentsOf: childURL.appendingPathComponent("injections.scm")),
           let query = try? Query(language: language, data: data) {
            queries[.injections] = query
        }
        if let data = try? Data(contentsOf: childURL.appendingPathComponent("locals.scm")),
           let query = try? Query(language: language, data: data) {
            queries[.locals] = query
        }

        guard queries[.highlights] != nil else {
            return try makeCodeConfiguration(language: language, name: name, bundleName: childBundle)
        }
        return LanguageConfiguration(language, name: name, queries: queries)
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

    /// Test seam: the capture names in the highlights query for a fenced-code
    /// language, or nil if it doesn't resolve. Lets tests confirm that an
    /// inherited grammar (TypeScript, C++) actually merged its parent's rules.
    static func highlightsCaptureNames(forFence name: String) -> [String]? {
        guard let config = makeLanguageProvider()(name),
              let highlights = config.queries[.highlights] else { return nil }
        return (0..<highlights.captureCount).compactMap { highlights.captureName(for: $0) }
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
