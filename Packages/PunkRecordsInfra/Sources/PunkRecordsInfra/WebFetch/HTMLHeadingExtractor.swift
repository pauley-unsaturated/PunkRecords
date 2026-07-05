import Foundation
import PunkRecordsCore
import SwiftSoup

/// Pulls h1–h3 headings out of a SwiftSoup element in document order,
/// preserving each heading's own `id` attribute as a candidate anchor. Shared
/// by Tier 1 (Readability) and Tier 2 (Readability.js result mapping) so both
/// feed identical ``WebHeadings/RawHeading`` values into the Core anchor
/// assignment. Infra-side because it speaks SwiftSoup.
enum HTMLHeadingExtractor {
    static func rawHeadings(from element: Element) -> [WebHeadings.RawHeading] {
        let nodes = (try? element.select("h1, h2, h3").array()) ?? []
        return nodes.compactMap { node in
            let level = Int(String(node.tagName().dropFirst())) ?? 1
            let text = ((try? node.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let id = node.id().trimmingCharacters(in: .whitespacesAndNewlines)
            return WebHeadings.RawHeading(level: level, text: text, anchorID: id.isEmpty ? nil : id)
        }
    }
}
