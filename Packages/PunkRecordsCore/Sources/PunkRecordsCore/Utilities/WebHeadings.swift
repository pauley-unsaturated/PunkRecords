import Foundation

/// Pure heading-model construction for fetched web content. The Infra tiers do
/// the SwiftSoup/WebKit DOM walking and hand this a flat list of ``RawHeading``
/// (level, text, and the element's own `id` if it had one); this assigns final,
/// document-unique anchor ids and filters to the h1–h3 range. Kept in Core so
/// anchor assignment is deterministic and unit-tested without a parser.
public enum WebHeadings {

    /// A heading as seen in source order before anchor assignment. `anchorID`
    /// is the source element's own `id` attribute when present (to preserve
    /// deep-links the page already publishes), else `nil`.
    public struct RawHeading: Sendable, Equatable {
        public let level: Int
        public let text: String
        public let anchorID: String?

        public init(level: Int, text: String, anchorID: String? = nil) {
            self.level = level
            self.text = text
            self.anchorID = anchorID
        }
    }

    /// Build the final ``WebHeading`` outline from raw headings:
    ///   - Drops anything outside levels 1–3 and blank-text headings.
    ///   - Preserves a source `id` verbatim when present and non-empty.
    ///   - Generates a slug (see ``WebSlug``) otherwise.
    ///   - Guarantees every `anchorID` is document-unique, disambiguating both
    ///     generated and preserved ids against those already taken.
    public static func build(from raw: [RawHeading]) -> [WebHeading] {
        var taken = Set<String>()
        var result: [WebHeading] = []
        for heading in raw {
            guard (1...3).contains(heading.level) else { continue }
            let text = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let base: String
            if let id = heading.anchorID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                base = id
            } else {
                base = WebSlug.slug(for: text)
            }
            let anchor = WebSlug.disambiguate(base, taken: taken)
            taken.insert(anchor)
            result.append(WebHeading(level: heading.level, text: text, anchorID: anchor))
        }
        return result
    }

    /// Extract raw h1–h3 headings from markdown (used for the Jina tier, whose
    /// output is already markdown and carries no source `id` attributes). Reuses
    /// ``HeadingOutline`` so fenced code blocks are correctly ignored.
    public static func rawHeadings(fromMarkdown markdown: String) -> [RawHeading] {
        HeadingOutline.parse(markdown)
            .filter { (1...3).contains($0.level) }
            .map { RawHeading(level: $0.level, text: $0.title, anchorID: nil) }
    }
}
