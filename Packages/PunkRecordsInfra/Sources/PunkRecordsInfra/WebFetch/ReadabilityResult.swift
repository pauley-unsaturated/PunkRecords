import Foundation
import PunkRecordsCore
import SwiftSoup

/// The raw parse result Mozilla's Readability.js returns from `.parse()`, as
/// pulled back across the `WKWebView` JavaScript bridge in Tier 2. Mirrors the
/// JS object's `{ title, byline, content, textContent }` shape.
struct ReadabilityResult: Sendable, Equatable {
    /// `.title` — the article title Readability derived.
    let title: String?
    /// `.byline` — author line, if any.
    let byline: String?
    /// `.content` — reader-mode article body as an HTML string.
    let contentHTML: String
    /// `.textContent` — the same body as plain text; a clean length signal.
    let textContent: String
}

/// Runs Mozilla's Readability.js against a fully-rendered page and returns its
/// result. The production implementation is `WebKitReadabilityExtractor` (an
/// invisible `WKWebView`); tests inject a stub returning fixture results so the
/// orchestration and the ``ReadabilityResultMapper`` mapping are covered without
/// a live browser.
protocol BrowserContentExtracting: Sendable {
    func extract(url: URL) async throws -> ReadabilityResult
}

/// Maps a ``ReadabilityResult`` (Readability.js output) into the common
/// ``ExtractedArticle`` intermediate: parse the reader HTML, convert to
/// markdown, and pull the heading outline. Pure and offline — this is the
/// "JS-result → model" seam the Tier 2 tests exercise with fixtures.
enum ReadabilityResultMapper {
    static func map(_ result: ReadabilityResult, baseURL: URL?) throws -> ExtractedArticle {
        let root: Element
        do {
            let fragment = try SwiftSoup.parseBodyFragment(result.contentHTML, baseURL?.absoluteString ?? "")
            root = fragment.body() ?? fragment
        } catch {
            throw WebFetchError.transport("Readability content parse failed: \(error.localizedDescription)")
        }

        let rawHeadings = HTMLHeadingExtractor.rawHeadings(from: root)
        let markdown = HTMLToMarkdown.markdown(from: root, baseURL: baseURL)

        let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false ? title : rawHeadings.first?.text) ?? "Untitled"
        let byline = result.byline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let textLength = result.textContent.isEmpty
            ? ((try? root.text().count) ?? markdown.count)
            : result.textContent.count

        return ExtractedArticle(
            title: resolvedTitle,
            byline: (byline?.isEmpty == false) ? byline : nil,
            contentMarkdown: markdown,
            rawHeadings: rawHeadings,
            canonicalURL: nil,
            textLength: textLength
        )
    }
}
