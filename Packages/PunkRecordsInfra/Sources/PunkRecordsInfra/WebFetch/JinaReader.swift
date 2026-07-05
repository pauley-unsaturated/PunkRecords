import Foundation
import PunkRecordsCore

/// Tier 3 of the web-fetch ladder: the remote Jina Reader API (`r.jina.ai`),
/// which renders and cleans a page server-side and returns markdown. Opt-in
/// only — the orchestrator must confirm consent (``WebFetchConsentPolicy``)
/// before ever calling ``endpoint(for:)``, because the URL leaves the device.
///
/// Stateless helpers: URL construction and response→model parsing. The actual
/// GET is performed by the orchestrator's shared ``WebHTTPClient`` so consent
/// gating has a single choke point and tests can assert no request escaped.
enum JinaReader {

    /// The Jina Reader endpoint for a target URL: `https://r.jina.ai/<absolute
    /// target URL>`. The target is appended raw (Jina expects the full URL,
    /// including scheme, as the path).
    static func endpoint(for url: URL) -> URL {
        // Jina takes the target URL verbatim after the host. Build via string so
        // the target's own scheme/query survive rather than being re-encoded.
        URL(string: "https://r.jina.ai/\(url.absoluteString)") ?? url
    }

    /// Suggested request headers: ask Jina for markdown output.
    static var requestHeaders: [String: String] {
        ["Accept": "text/plain", "X-Return-Format": "markdown"]
    }

    /// Parse a Jina Reader response body into an ``ExtractedArticle``. Jina's
    /// default response prefixes a small header block:
    ///
    ///     Title: Example
    ///     URL Source: https://example.com/
    ///     Markdown Content:
    ///     # Example
    ///     …body…
    ///
    /// We lift `Title:` and treat everything after `Markdown Content:` as the
    /// body; if the header block is absent, the whole response is the body.
    static func parse(_ body: String, sourceURL: URL) -> ExtractedArticle {
        var title: String?
        var markdown = body

        if let range = body.range(of: "Markdown Content:") {
            let header = String(body[..<range.lowerBound])
            markdown = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for line in header.split(separator: "\n") where line.hasPrefix("Title:") {
                title = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            }
        }

        markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawHeadings = WebHeadings.rawHeadings(fromMarkdown: markdown)
        let resolvedTitle = (title?.isEmpty == false ? title : rawHeadings.first?.text)
            ?? sourceURL.host
            ?? "Untitled"

        return ExtractedArticle(
            title: resolvedTitle,
            byline: nil,
            contentMarkdown: markdown,
            rawHeadings: rawHeadings,
            canonicalURL: nil,
            textLength: markdown.count
        )
    }
}
