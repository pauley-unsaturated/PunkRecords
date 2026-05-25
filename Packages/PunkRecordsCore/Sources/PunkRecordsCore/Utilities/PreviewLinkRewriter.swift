import Foundation

/// Rewrites a markdown body so the read-only preview can make `[[wikilinks]]`
/// and `#tags` clickable. Standard markdown links are left untouched (the
/// renderer already handles them).
///
/// Wikilinks and tags aren't standard markdown, so the renderer would show them
/// as literal text. We convert them to markdown links carrying a custom
/// `punk://` scheme that the preview's `OpenURLAction` interprets:
///
/// - `[[Target]]`        → `[Target](punk://note/Target)`
/// - `[[Target|alias]]`  → `[alias](punk://note/Target)`
/// - `#tag`              → `[#tag](punk://tag/tag)`
///
/// Rewriting is skipped inside fenced code blocks and inline code spans so
/// source like `#include` or `[[x]]` in a code sample is never turned into a
/// link.
public enum PreviewLinkRewriter {
    public static let scheme = "punk"
    public static let noteHost = "note"
    public static let tagHost = "tag"

    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/])#([A-Za-z][A-Za-z0-9_/-]*)"#
    )
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)

    /// Rewrite the markdown body, converting wikilinks and tags outside of code.
    public static func rewrite(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        // Preserve trailing newline behavior by splitting on "\n" and rejoining.
        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out.append(line)
                continue
            }
            out.append(inFence ? line : rewriteInline(line))
        }
        return out.joined(separator: "\n")
    }

    /// Rewrite a single line, leaving inline code spans (`...`) untouched.
    private static func rewriteInline(_ line: String) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        inlineCodeRegex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            // Rewrite the gap before this code span; keep the code span verbatim.
            let gap = NSRange(location: cursor, length: match.range.location - cursor)
            result += rewriteTokens(ns.substring(with: gap))
            result += ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += rewriteTokens(ns.substring(from: cursor))
        return result
    }

    /// Apply wikilink then tag substitution to a code-free fragment.
    private static func rewriteTokens(_ fragment: String) -> String {
        let afterWikilinks = replace(fragment, regex: wikilinkRegex) { inner in
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? inner
            let display = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : target
            return "[\(escapeLinkText(display))](\(noteURL(for: target)))"
        }
        return replace(afterWikilinks, regex: tagRegex) { name in
            "[#\(name)](\(tagURL(for: name)))"
        }
    }

    /// Replace every match of `regex` (capture group 1) using `transform`.
    private static func replace(
        _ string: String,
        regex: NSRegularExpression,
        transform: (String) -> String
    ) -> String {
        let ns = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return string }
        var result = ""
        var cursor = 0
        for match in matches {
            let whole = match.range
            result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            let inner = ns.substring(with: match.range(at: 1))
            result += transform(inner)
            cursor = whole.location + whole.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - URL construction

    public static func noteURL(for target: String) -> String {
        "\(scheme)://\(noteHost)/\(percentEncoded(target))"
    }

    public static func tagURL(for name: String) -> String {
        "\(scheme)://\(tagHost)/\(percentEncoded(name))"
    }

    private static func percentEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Escape `]` in displayed link text so it doesn't close the markdown link.
    private static func escapeLinkText(_ s: String) -> String {
        s.replacingOccurrences(of: "]", with: "\\]")
    }
}
