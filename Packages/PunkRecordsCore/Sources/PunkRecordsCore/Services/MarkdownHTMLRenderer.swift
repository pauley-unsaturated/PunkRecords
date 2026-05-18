import Foundation
import cmark_gfm

/// Renders a markdown document into a self-contained HTML file suitable
/// for sharing outside the vault. Strips YAML frontmatter, parses the
/// body via cmark-gfm, and wraps the rendered HTML in a minimal document
/// with print-friendly styling.
///
/// Wikilinks (`[[Note Name]]`) are left as literal text — recipients
/// outside the vault have no resolver, so dead anchors would be worse
/// than visible source. A future iteration can replace them with styled
/// spans + tooltips.
public enum MarkdownHTMLRenderer {

    /// Renders the given markdown content to a complete `<!doctype html>` document.
    /// Pass `title` to populate the `<title>` and the visible `<h1>` (if the body
    /// doesn't already start with one).
    public static func renderHTMLDocument(
        markdown: String,
        title: String
    ) -> String {
        let (_, body) = MarkdownParser().parseFrontmatter(from: markdown)
        let bodyHTML = renderHTMLFragment(markdown: body)
        return wrapDocument(title: title, bodyHTML: bodyHTML)
    }

    /// Renders ONLY the body fragment — the inner HTML that would live inside
    /// `<article>...</article>`. Useful for previews and tests; doesn't include
    /// `<html>`, `<head>`, or styling.
    public static func renderHTMLFragment(markdown: String) -> String {
        var rendered = ""
        markdown.withCString { cStr in
            let len = strlen(cStr)
            guard let node = cmark_parse_document(cStr, len, CMARK_OPT_DEFAULT) else { return }
            defer { cmark_node_free(node) }
            guard let html = cmark_render_html(node, CMARK_OPT_DEFAULT, nil) else { return }
            defer { free(html) }
            rendered = String(cString: html)
        }
        return rendered
    }

    private static func wrapDocument(title: String, bodyHTML: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="generator" content="PunkRecords">
        <title>\(escapeHTML(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article>
        \(bodyHTML)
        </article>
        </body>
        </html>
        """
    }

    /// Minimal print-friendly stylesheet. Avoids web fonts so the file is
    /// fully self-contained and renders identically offline.
    private static let stylesheet = """
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 16px;
          line-height: 1.6;
          max-width: 760px;
          margin: 2.5em auto;
          padding: 0 1.5em;
          color: #1c1c1e;
          background: #fff;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #f5f5f7; background: #1c1c1e; }
          code, pre { background: #2c2c2e; }
          a { color: #0a84ff; }
        }
        h1, h2, h3, h4 { line-height: 1.25; margin-top: 1.5em; }
        h1 { border-bottom: 1px solid #d2d2d7; padding-bottom: 0.3em; }
        code { background: #f5f5f7; padding: 0.15em 0.4em; border-radius: 3px; font-size: 0.92em; }
        pre { background: #f5f5f7; padding: 1em; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote {
          margin: 0; padding: 0.4em 1em;
          color: #555; border-left: 3px solid #d2d2d7;
        }
        table { border-collapse: collapse; width: 100%; }
        th, td { padding: 0.4em 0.7em; border: 1px solid #d2d2d7; text-align: left; }
        @media print {
          body { max-width: none; margin: 0; padding: 0; color: #000; background: #fff; }
        }
        """

    private static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
