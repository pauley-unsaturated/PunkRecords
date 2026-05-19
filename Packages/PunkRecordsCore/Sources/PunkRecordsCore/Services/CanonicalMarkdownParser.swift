import Foundation
import Markdown

/// Canonical Markdown parser backed by swift-markdown (cmark-gfm).
///
/// Runs on save and feeds future export and Quick Look paths. The live
/// in-editor styling uses tree-sitter for speed; this provides the
/// authoritative AST when correctness matters.
public struct CanonicalMarkdownParser: Sendable {
    public init() {}

    /// Parse the given source into a `Markdown.Document` AST.
    ///
    /// Parsing never throws for valid UTF-8 — cmark-gfm tolerates any input —
    /// so callers can treat the result as a snapshot of the document structure.
    public func parse(_ source: String) -> Markdown.Document {
        Markdown.Document(parsing: source)
    }

    /// Lightweight structural summary used by tests and tooling that want to
    /// validate a corpus parses without walking the full AST.
    public func summary(of source: String) -> Summary {
        let doc = parse(source)
        var counts = Summary.Counts()
        for child in doc.children {
            countNode(child, into: &counts)
        }
        return Summary(counts: counts, hasFrontmatter: source.hasPrefix("---"))
    }

    private func countNode(_ node: any Markup, into counts: inout Summary.Counts) {
        switch node {
        case is Heading: counts.headings += 1
        case is Paragraph: counts.paragraphs += 1
        case is CodeBlock: counts.codeBlocks += 1
        case is BlockQuote: counts.blockQuotes += 1
        case is UnorderedList, is OrderedList: counts.lists += 1
        case is ThematicBreak: counts.thematicBreaks += 1
        case is Table: counts.tables += 1
        default: break
        }
        for child in node.children {
            countNode(child, into: &counts)
        }
    }

    public struct Summary: Sendable, Equatable {
        public struct Counts: Sendable, Equatable {
            public var headings = 0
            public var paragraphs = 0
            public var codeBlocks = 0
            public var blockQuotes = 0
            public var lists = 0
            public var thematicBreaks = 0
            public var tables = 0
        }

        public let counts: Counts
        public let hasFrontmatter: Bool
    }
}
