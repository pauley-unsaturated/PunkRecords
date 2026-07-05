import Foundation
import PunkRecordsCore
import SwiftSoup

/// Tier 1 of the web-fetch ladder: an offline, dependency-light port of the
/// Readability content-scoring algorithm on top of SwiftSoup. Given raw HTML it
/// strips boilerplate, scores block elements by text/comma density with
/// class/id weighting, picks the highest-scoring container plus its strong
/// siblings, and renders that subtree to markdown. No JavaScript, no network —
/// fast and private. Escalation to Tier 2 is decided by ``WebFetchTierPolicy``
/// using the returned ``ExtractedArticle/textLength``.
///
/// Heavily based on Arc90/Mozilla Readability's scoring heuristics, reimplemented
/// in Swift. It intentionally covers the common article shape rather than every
/// Readability edge case; JS-rendered or unusual pages fall through to Tier 2.
struct ReadabilityExtractor: Sendable {

    /// Extract structured content from `html`. `baseURL` resolves relative links
    /// and is the fallback canonical URL. Pure and offline — safe to unit-test
    /// against local fixtures.
    func extract(html: String, baseURL: URL?) throws -> ExtractedArticle {
        let doc: SwiftSoup.Document
        do {
            doc = try SwiftSoup.parse(html, baseURL?.absoluteString ?? "")
        } catch {
            throw WebFetchError.transport("HTML parse failed: \(error.localizedDescription)")
        }

        // Read metadata BEFORE stripping <meta>/<link>/<title>.
        let title = extractTitle(doc)
        let byline = extractByline(doc)
        let canonical = extractCanonical(doc, baseURL: baseURL)

        stripBoilerplate(doc)

        guard let bodyEl = doc.body() else {
            return ExtractedArticle(
                title: title, byline: byline, contentMarkdown: "",
                rawHeadings: [], canonicalURL: canonical, textLength: 0
            )
        }

        var scores: [ObjectIdentifier: Double] = [:]
        var candidates: [ObjectIdentifier: Element] = [:]
        scoreParagraphs(in: bodyEl, scores: &scores, candidates: &candidates)

        let article = topArticleElement(bodyEl, scores: &scores, candidates: candidates)
        cleanArticle(article)

        let rawHeadings = HTMLHeadingExtractor.rawHeadings(from: article)
        let markdown = HTMLToMarkdown.markdown(from: article, baseURL: baseURL)
        let textLength = (try? article.text().count) ?? markdown.count

        return ExtractedArticle(
            title: title,
            byline: byline,
            contentMarkdown: markdown,
            rawHeadings: rawHeadings,
            canonicalURL: canonical,
            textLength: textLength
        )
    }

    // MARK: - Scoring

    private func scoreParagraphs(
        in body: Element,
        scores: inout [ObjectIdentifier: Double],
        candidates: inout [ObjectIdentifier: Element]
    ) {
        let paragraphs = (try? body.select("p, td, pre, blockquote").array()) ?? []
        for para in paragraphs {
            let text = (try? para.text()) ?? ""
            guard text.count >= 25 else { continue }

            var contentScore = 1.0
            contentScore += Double(text.filter { $0 == "," }.count)
            contentScore += Swift.min((Double(text.count) / 100.0).rounded(.down), 3.0)

            if let parent = para.parent() {
                ensureInitialized(parent, scores: &scores, candidates: &candidates)
                scores[ObjectIdentifier(parent), default: 0] += contentScore
                if let grand = parent.parent() {
                    ensureInitialized(grand, scores: &scores, candidates: &candidates)
                    scores[ObjectIdentifier(grand), default: 0] += contentScore / 2.0
                }
            }
        }
    }

    private func ensureInitialized(
        _ element: Element,
        scores: inout [ObjectIdentifier: Double],
        candidates: inout [ObjectIdentifier: Element]
    ) {
        let key = ObjectIdentifier(element)
        guard scores[key] == nil else { return }
        scores[key] = baseScore(element) + classWeight(element)
        candidates[key] = element
    }

    /// Pick the top-scoring candidate (score scaled by 1 − link density) and
    /// fold in strong sibling blocks, mutating the DOM in place so the returned
    /// element is a self-contained article root.
    private func topArticleElement(
        _ body: Element,
        scores: inout [ObjectIdentifier: Double],
        candidates: [ObjectIdentifier: Element]
    ) -> Element {
        var top: Element?
        var topScore = -1.0
        for (key, element) in candidates {
            let scaled = (scores[key] ?? 0) * (1.0 - linkDensity(element))
            scores[key] = scaled
            if scaled > topScore {
                topScore = scaled
                top = element
            }
        }

        guard let topCandidate = top, topScore > 0 else { return body }

        // Merge in siblings that score well or read like content paragraphs.
        guard let parent = topCandidate.parent(), parent.tagName().lowercased() != "html" else {
            return topCandidate
        }
        let threshold = Swift.max(10.0, topScore * 0.2)
        for sibling in parent.children().array() where sibling !== topCandidate {
            let siblingScore = scores[ObjectIdentifier(sibling)] ?? 0
            let keep = siblingScore >= threshold || looksLikeContentParagraph(sibling)
            if !keep { try? sibling.remove() }
        }
        return parent
    }

    private func looksLikeContentParagraph(_ element: Element) -> Bool {
        guard element.tagName().lowercased() == "p" else { return false }
        let text = (try? element.text()) ?? ""
        if text.count > 80, linkDensity(element) < 0.25 { return true }
        if text.count < 80, linkDensity(element) == 0, text.hasSuffix(".") { return true }
        return false
    }

    // MARK: - Cleaning

    private func stripBoilerplate(_ doc: SwiftSoup.Document) {
        let removeTags = "script, style, noscript, nav, header, footer, aside, form, "
            + "iframe, svg, button, input, select, textarea, label, template, link, "
            + "meta, figure figcaption, [aria-hidden=true]"
        _ = try? doc.select(removeTags).remove()

        guard let bodyEl = doc.body() else { return }
        let all = (try? bodyEl.getAllElements())?.array() ?? []
        for element in all {
            let identity = (((try? element.className()) ?? "") + " " + element.id()).lowercased()
            guard !identity.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if matches(identity, Self.unlikelyPattern), !matches(identity, Self.maybePattern) {
                // Never strip the body/main content wrapper itself.
                if element.tagName().lowercased() != "body" { try? element.remove() }
            }
        }
    }

    /// Remove obviously non-content descendants left inside the chosen article.
    private func cleanArticle(_ article: Element) {
        _ = try? article.select("script, style, noscript, form, iframe, svg, button, "
            + "input, select, textarea, .share, .social, .related, .newsletter").remove()
    }

    // MARK: - Metadata

    private func extractTitle(_ doc: SwiftSoup.Document) -> String {
        if let og = metaContent(doc, "meta[property=og:title]"), !og.isEmpty { return cleanTitle(og) }
        let docTitle = ((try? doc.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !docTitle.isEmpty { return cleanTitle(docTitle) }
        if let h1 = try? doc.select("h1").first(), let text = try? h1.text(), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Untitled"
    }

    /// Strip a trailing " | Site Name" / " - Site" suffix from a `<title>` when
    /// the leading part is substantial, matching Readability's title heuristic.
    private func cleanTitle(_ title: String) -> String {
        for separator in [" | ", " – ", " — ", " - ", " :: " ] {
            if let range = title.range(of: separator, options: .backwards) {
                let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if head.count >= 15 { return head }
            }
        }
        return title
    }

    private func extractByline(_ doc: SwiftSoup.Document) -> String? {
        let candidates = [
            "meta[name=author]", "meta[property=article:author]",
            "meta[name=twitter:creator]", "[rel=author]", ".byline", ".author",
        ]
        for selector in candidates {
            if selector.hasPrefix("meta"), let content = metaContent(doc, selector), !content.isEmpty {
                return content
            }
            if let element = try? doc.select(selector).first(),
               let text = try? element.text() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count < 120 { return trimmed }
            }
        }
        return nil
    }

    private func extractCanonical(_ doc: SwiftSoup.Document, baseURL: URL?) -> URL? {
        if let href = try? doc.select("link[rel=canonical]").first()?.attr("href"),
           let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            return url
        }
        if let og = metaContent(doc, "meta[property=og:url]"),
           let url = URL(string: og, relativeTo: baseURL)?.absoluteURL {
            return url
        }
        return nil
    }

    private func metaContent(_ doc: SwiftSoup.Document, _ selector: String) -> String? {
        guard let element = try? doc.select(selector).first(),
              let content = try? element.attr("content") else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Element weighting

    private func baseScore(_ element: Element) -> Double {
        switch element.tagName().lowercased() {
        case "div", "article", "section", "main": return 5
        case "pre", "td", "blockquote": return 3
        case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": return -3
        case "h1", "h2", "h3", "h4", "h5", "h6", "th": return -5
        default: return 0
        }
    }

    private func classWeight(_ element: Element) -> Double {
        let identity = (((try? element.className()) ?? "") + " " + element.id()).lowercased()
        var weight = 0.0
        if matches(identity, Self.positivePattern) { weight += 25 }
        if matches(identity, Self.negativePattern) { weight -= 25 }
        return weight
    }

    private func linkDensity(_ element: Element) -> Double {
        let textLength = Double(((try? element.text()) ?? "").count)
        guard textLength > 0 else { return 0 }
        let links = (try? element.select("a").array()) ?? []
        let linkLength = links.reduce(0.0) { $0 + Double(((try? $1.text()) ?? "").count) }
        return Swift.min(linkLength / textLength, 1.0)
    }

    // MARK: - Regex helpers

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let positivePattern =
        "article|body|content|entry|main|page|post|text|blog|story|column"
    private static let negativePattern =
        "combx|comment|com-|contact|foot|footer|footnote|masthead|media|meta|"
        + "outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|"
        + "tool|widget|hidden|nav|menu|banner|social|share|popup|cookie|newsletter"
    private static let unlikelyPattern =
        "-ad-|banner|breadcrumb|combx|comment|community|cover-wrap|disqus|extra|"
        + "gdpr|legends|menu|related|remark|replies|rss|shoutbox|sidebar|"
        + "skyscraper|social|sponsor|supplemental|agegate|pagination|pager|popup|"
        + "cookie|newsletter|subscribe|promo"
    private static let maybePattern =
        "and|article|body|column|content|main|shadow"
}
