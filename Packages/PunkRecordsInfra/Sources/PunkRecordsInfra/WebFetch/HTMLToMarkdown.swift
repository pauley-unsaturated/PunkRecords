import Foundation
import SwiftSoup

/// Converts a cleaned SwiftSoup element subtree into markdown. Deliberately a
/// pragmatic subset — headings, paragraphs, lists, blockquotes, code, links,
/// emphasis, images, rules — matching what reader-mode extraction leaves behind
/// after boilerplate is stripped. Lives in Infra because it speaks SwiftSoup;
/// its output feeds the pure Core ``WebContent`` model.
enum HTMLToMarkdown {

    /// Render `root`'s children to markdown. `baseURL`, when supplied, resolves
    /// relative `href`/`src` attributes to absolute URLs.
    static func markdown(from root: Element, baseURL: URL? = nil) -> String {
        let blocks = renderBlocks(of: root, baseURL: baseURL)
        return normalizeBlankLines(blocks.joined(separator: "\n\n"))
    }

    // MARK: - Block rendering

    /// Render the block-level structure of `element`'s children into a list of
    /// block strings (paragraphs, headings, list bodies, …). Consecutive inline
    /// nodes are coalesced into a single paragraph.
    private static func renderBlocks(of element: Element, baseURL: URL?) -> [String] {
        var blocks: [String] = []
        var inlineRun = ""

        func flushInline() {
            let trimmed = inlineRun.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(collapseInlineSpaces(trimmed)) }
            inlineRun = ""
        }

        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                inlineRun += text.text()
            } else if let child = node as? Element {
                if isBlockElement(child) {
                    flushInline()
                    blocks.append(contentsOf: renderBlockElement(child, baseURL: baseURL))
                } else {
                    inlineRun += renderInline(child, baseURL: baseURL)
                }
            }
        }
        flushInline()
        return blocks.filter { !$0.isEmpty }
    }

    private static func renderBlockElement(_ element: Element, baseURL: URL?) -> [String] {
        let tag = element.tagName().lowercased()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 1
            let text = collapseInlineSpaces(renderInlineChildren(element, baseURL: baseURL))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]

        case "p", "div", "section", "article", "main", "header", "footer", "figure", "figcaption":
            return renderBlocks(of: element, baseURL: baseURL)

        case "ul", "ol":
            return [renderList(element, ordered: tag == "ol", baseURL: baseURL)]

        case "blockquote":
            let inner = renderBlocks(of: element, baseURL: baseURL).joined(separator: "\n\n")
            let quoted = inner
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            return quoted.isEmpty ? [] : [quoted]

        case "pre":
            let code = element.getPreText()
            let trimmed = code.trimmingCharacters(in: CharacterSet.newlines)
            return trimmed.isEmpty ? [] : ["```\n\(trimmed)\n```"]

        case "hr":
            return ["---"]

        case "table":
            return renderTable(element, baseURL: baseURL)

        case "br":
            return []

        default:
            return renderBlocks(of: element, baseURL: baseURL)
        }
    }

    private static func renderList(_ element: Element, ordered: Bool, baseURL: URL?, depth: Int = 0) -> String {
        var lines: [String] = []
        var index = 1
        let indent = String(repeating: "  ", count: depth)
        for case let li as Element in element.getChildNodes() where li.tagName().lowercased() == "li" {
            let marker = ordered ? "\(index). " : "- "
            // Split the item into its own inline text and any nested lists.
            var inlineParts = ""
            var nested: [String] = []
            for node in li.getChildNodes() {
                if let text = node as? TextNode {
                    inlineParts += text.text()
                } else if let child = node as? Element {
                    let childTag = child.tagName().lowercased()
                    if childTag == "ul" || childTag == "ol" {
                        nested.append(renderList(child, ordered: childTag == "ol", baseURL: baseURL, depth: depth + 1))
                    } else if isBlockElement(child) {
                        inlineParts += " " + collapseInlineSpaces(renderInlineChildren(child, baseURL: baseURL))
                    } else {
                        inlineParts += renderInline(child, baseURL: baseURL)
                    }
                }
            }
            let itemText = collapseInlineSpaces(inlineParts).trimmingCharacters(in: .whitespacesAndNewlines)
            if !itemText.isEmpty {
                lines.append("\(indent)\(marker)\(itemText)")
            }
            lines.append(contentsOf: nested)
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ element: Element, baseURL: URL?) -> [String] {
        var rows: [[String]] = []
        for tr in (try? element.select("tr").array()) ?? [] {
            var cells: [String] = []
            for case let cell as Element in tr.getChildNodes()
            where ["td", "th"].contains(cell.tagName().lowercased()) {
                cells.append(collapseInlineSpaces(renderInlineChildren(cell, baseURL: baseURL))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "|", with: "\\|"))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard let header = rows.first else { return [] }
        var out = "| " + header.joined(separator: " | ") + " |"
        out += "\n| " + header.map { _ in "---" }.joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            out += "\n| " + row.joined(separator: " | ") + " |"
        }
        return [out]
    }

    // MARK: - Inline rendering

    private static func renderInlineChildren(_ element: Element, baseURL: URL?) -> String {
        var out = ""
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                out += text.text()
            } else if let child = node as? Element {
                out += renderInline(child, baseURL: baseURL)
            }
        }
        return out
    }

    private static func renderInline(_ element: Element, baseURL: URL?) -> String {
        let tag = element.tagName().lowercased()
        switch tag {
        case "br":
            return "\n"
        case "a":
            let inner = collapseInlineSpaces(renderInlineChildren(element, baseURL: baseURL))
            guard let href = resolvedAttr("href", of: element, baseURL: baseURL), !href.isEmpty else { return inner }
            return inner.isEmpty ? "" : "[\(inner)](\(href))"
        case "strong", "b":
            let inner = collapseInlineSpaces(renderInlineChildren(element, baseURL: baseURL))
            return inner.isEmpty ? "" : "**\(inner)**"
        case "em", "i":
            let inner = collapseInlineSpaces(renderInlineChildren(element, baseURL: baseURL))
            return inner.isEmpty ? "" : "*\(inner)*"
        case "code":
            let inner = (try? element.text()) ?? renderInlineChildren(element, baseURL: baseURL)
            return inner.isEmpty ? "" : "`\(inner)`"
        case "del", "s", "strike":
            let inner = collapseInlineSpaces(renderInlineChildren(element, baseURL: baseURL))
            return inner.isEmpty ? "" : "~~\(inner)~~"
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            guard let src = resolvedAttr("src", of: element, baseURL: baseURL), !src.isEmpty else { return "" }
            return "![\(alt)](\(src))"
        default:
            return renderInlineChildren(element, baseURL: baseURL)
        }
    }

    // MARK: - Helpers

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "tbody", "thead", "tr", "ul",
    ]

    private static func isBlockElement(_ element: Element) -> Bool {
        blockTags.contains(element.tagName().lowercased())
    }

    private static func resolvedAttr(_ name: String, of element: Element, baseURL: URL?) -> String? {
        guard let raw = try? element.attr(name), !raw.isEmpty else { return nil }
        if let baseURL, let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
            return resolved.absoluteString
        }
        return raw
    }

    /// Collapse runs of ASCII/Unicode whitespace to single spaces (HTML inline
    /// whitespace semantics), preserving explicit `\n` hard breaks.
    private static func collapseInlineSpaces(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for char in text {
            if char == "\n" {
                result += "\n"
                pendingSpace = false
            } else if char.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace, !result.isEmpty, result.last != "\n" { result += " " }
                pendingSpace = false
                result.append(char)
            }
        }
        return result
    }

    /// Collapse 3+ consecutive newlines to a single blank line.
    private static func normalizeBlankLines(_ text: String) -> String {
        var out = text
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Element {
    /// Text content of a `<pre>` with SwiftSoup's whitespace preservation.
    func getPreText() -> String {
        (try? self.text()) ?? ""
    }
}
