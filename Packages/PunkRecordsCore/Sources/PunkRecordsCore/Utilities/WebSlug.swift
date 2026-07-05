import Foundation

/// Pure slug generation for web-content anchors and cache filenames. Produces
/// URL-fragment-safe, filesystem-safe ASCII slugs from arbitrary heading text
/// or URLs. Kept in Core so anchor ids and cache paths are deterministic and
/// unit-tested independently of the SwiftSoup/WebKit extraction in Infra.
public enum WebSlug {

    /// A lowercase, hyphen-delimited slug of `text`:
    ///   - Unicode is folded to ASCII where a sensible transliteration exists
    ///     (accents stripped: `Café` → `cafe`); otherwise non-ASCII word
    ///     characters are kept lowercased if they are letters/digits.
    ///   - Runs of punctuation/whitespace collapse to a single hyphen.
    ///   - Leading/trailing hyphens are trimmed.
    ///   - An empty or fully-stripped input yields `"section"` so callers never
    ///     produce an empty anchor/filename.
    public static func slug(for text: String) -> String {
        // Fold diacritics to base ASCII where possible (Café → Cafe).
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)

        var out = String.UnicodeScalarView()
        var lastWasHyphen = true // start true so leading separators are dropped
        for scalar in folded.lowercased().unicodeScalars {
            if isSlugWordScalar(scalar) {
                out.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        var slug = String(out)
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "section" : slug
    }

    /// Slug derived from a URL, suitable for a cache filename: `host` plus the
    /// path, so `https://example.com/blog/Post?x=1#frag` →
    /// `example-com-blog-post`. Query and fragment are dropped (they don't
    /// change the cached HTML we key on). Falls back to a slug of the whole
    /// string for non-standard URLs.
    public static func slug(forURL url: URL) -> String {
        let host = url.host?.replacingOccurrences(of: ".", with: "-") ?? ""
        let path = url.path
        let combined = host.isEmpty ? path : (path.isEmpty || path == "/" ? host : "\(host)\(path)")
        let candidate = combined.isEmpty ? url.absoluteString : combined
        return slug(for: candidate)
    }

    /// Assign document-unique slugs to `texts`, in order. The first occurrence
    /// keeps its base slug; later collisions get `-2`, `-3`, … suffixes.
    /// Mirrors how HTML anchor generators (GitHub, Readability) disambiguate.
    public static func uniqueSlugs(for texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return texts.map { text in
            let base = slug(for: text)
            let seen = counts[base, default: 0]
            counts[base] = seen + 1
            return seen == 0 ? base : "\(base)-\(seen + 1)"
        }
    }

    /// Disambiguate an already-chosen `candidate` against a set of `taken`
    /// slugs, appending `-2`, `-3`, … until unique. Used when some anchors are
    /// preserved verbatim (an element's own `id`) and must not be clobbered by
    /// generated ones.
    public static func disambiguate(_ candidate: String, taken: Set<String>) -> String {
        guard taken.contains(candidate) else { return candidate }
        var n = 2
        while taken.contains("\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }

    // MARK: - Private

    private static func isSlugWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        // ASCII alphanumerics only after diacritic folding — keeps anchors and
        // filenames portable. Non-ASCII letters that didn't fold (e.g. CJK) are
        // treated as separators; a heading that is entirely CJK falls back to
        // "section", which is acceptable for anchors.
        (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
            || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
    }
}
