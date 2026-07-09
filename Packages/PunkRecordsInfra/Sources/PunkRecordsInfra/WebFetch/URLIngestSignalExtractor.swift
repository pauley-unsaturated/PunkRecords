import Foundation
import PunkRecordsCore
import SwiftSoup

/// Extracts the SwiftSoup-derived signals ``URLIngestClassifier`` needs from
/// raw HTML: `og:type`, `<html lang>`, and a flattened class/id "identity
/// blob" ``PaywallDetector`` substring-searches for known paywall markers. A
/// sibling to ``ReadabilityExtractor`` — reads the SAME html string Tier 1
/// already downloaded, so a caller that has both computes ingest signals
/// without an extra network round trip.
///
/// Best-effort by design: a parse failure yields empty/nil signals rather
/// than throwing, since these are SUPPLEMENTARY to the primary `WebContent`
/// (already produced by `ReadabilityExtractor`/the browser tier) — a signal
/// extraction failure shouldn't fail the whole fetch.
enum URLIngestSignalExtractor {
    struct Signals: Equatable {
        let ogType: String?
        let htmlLang: String?
        let bodyClassIdentityBlob: String
    }

    static func extract(html: String) -> Signals {
        guard let doc = try? SwiftSoup.parse(html) else {
            return Signals(ogType: nil, htmlLang: nil, bodyClassIdentityBlob: "")
        }
        return Signals(
            ogType: metaContent(doc, "meta[property=og:type]"),
            htmlLang: extractHTMLLang(doc),
            bodyClassIdentityBlob: bodyClassIdentityBlob(doc)
        )
    }

    private static func metaContent(_ doc: SwiftSoup.Document, _ selector: String) -> String? {
        guard let element = try? doc.select(selector).first(), let content = try? element.attr("content") else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractHTMLLang(_ doc: SwiftSoup.Document) -> String? {
        guard let htmlElement = try? doc.select("html").first() else { return nil }
        guard let lang = try? htmlElement.attr("lang") else { return nil }
        let trimmed = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lowercased, space-joined concatenation of every `class`/`id` attribute
    /// value found on elements within the page body.
    private static func bodyClassIdentityBlob(_ doc: SwiftSoup.Document) -> String {
        guard let body = doc.body() else { return "" }
        let all = (try? body.getAllElements())?.array() ?? []
        let identities = all.compactMap { element -> String? in
            let classes = (try? element.className()) ?? ""
            let id = element.id()
            let combined = (classes + " " + id).trimmingCharacters(in: .whitespaces)
            return combined.isEmpty ? nil : combined
        }
        return identities.joined(separator: " ").lowercased()
    }
}
