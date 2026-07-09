import Foundation

/// Assembles a fetched-and-summarized web page into PunkRecords' web-summary
/// note schema: destination path `Web/{YYYY-MM-DD}-{slug}.md` (slug derived
/// from the page title, numeric-suffixed on collision) and a full markdown
/// document with YAML frontmatter.
///
/// Frontmatter shape (PUNK-ddq): the standard `id`/`created`/`modified` every
/// PunkRecords note carries (required for document identity — see
/// ``MarkdownParser/parse(content:filename:)``'s `needsIDAssigned`), followed
/// by the user-facing fields (`title`, `source_url`, `source_domain`,
/// `author`, `published`, `tags`, `type`, `status`), followed by a
/// `_punkrecords:` block namespacing implementation details (fetch time,
/// extraction tier, summarization model/prompt version, word count/reading
/// time, and validator/citation health) so a human skimming the note sees
/// only what matters to them at the top level.
///
/// Pure and deterministic — no I/O, no actor, no LLM calls. The caller (the
/// App-layer URL-summarize flow) supplies the already-fetched ``WebContent``
/// and the already-produced ``WebSummaryPostProcessor/Result``; `now` and `id`
/// are injected so callers get reproducible output in tests and a real caller
/// can just take the defaults.
public enum WebSummaryNoteWriter {

    /// Everything a caller needs to persist the note: the ready-to-save
    /// markdown document, its vault-relative destination path, and the pieces
    /// (title, tags, id) needed to construct a matching ``Document``.
    public struct Output: Sendable, Equatable {
        public let markdown: String
        public let path: RelativePath
        public let title: String
        public let tags: [String]
        public let id: DocumentID
    }

    /// Root folder every web-summary note lands under.
    public static let folder: RelativePath = "Web"

    /// The `tags` value every web-summary note carries, regardless of what
    /// (if anything) the caller passes — the type marker that makes the note
    /// findable/filterable as a class, independent of the `type:` frontmatter
    /// field (which downstream tooling that doesn't parse nested/typed
    /// frontmatter can't rely on).
    public static let baseTag = "web-summary"

    /// Longest slug (in characters) derived from a page title, so a very long
    /// title doesn't produce an unwieldy filename. Truncated at a hyphen
    /// boundary where possible.
    static let maxSlugLength = 60

    /// Assemble the note for a fetched-and-summarized page.
    ///
    /// - Parameters:
    ///   - content: The fetched page metadata (title, byline, source URL, tier, fetch time).
    ///   - summary: ``WebSummaryPostProcessor``'s rendered result — the 4-section
    ///     summary body markdown plus the decoded payload and unresolved-citation count.
    ///   - validatorIssueCount: `WebSummaryValidator.validate(payload:content:).count`
    ///     for `summary.payload`, so a caller can flag a structurally-imperfect summary.
    ///   - summaryModel: The model id used to produce the summary (e.g. `"claude-sonnet-4-6"`).
    ///   - tags: Additional tags for the note. ``baseTag`` is always included even
    ///     when omitted here; duplicates (case-insensitive) are dropped.
    ///   - status: The note's workflow status (e.g. `"unread"`).
    ///   - author: The known author, if any. Falls back to `content.byline` when
    ///     `nil`; the `author:` frontmatter key is omitted entirely when both are absent/blank.
    ///   - published: The known publish date, if any. No stage of the current
    ///     fetch/summarize pipeline extracts this (``WebContent`` carries no such
    ///     field) — the parameter exists so the schema is ready the day one does.
    ///     Omitted entirely when `nil`.
    ///   - now: The write time — determines the path's `{YYYY-MM-DD}` prefix AND
    ///     the frontmatter `created`/`modified`/timestamps. Injected for determinism.
    ///   - id: The note's stable id. Injected for determinism; a real caller can
    ///     take the default (a fresh ``DocumentID``).
    ///   - existingPaths: Vault-relative paths already in use. Collision detection
    ///     numeric-suffixes the slug (`-2`, `-3`, …) until the candidate isn't in this set.
    public static func write(
        content: WebContent,
        summary: WebSummaryPostProcessor.Result,
        validatorIssueCount: Int,
        summaryModel: String,
        tags: [String] = [],
        status: String = "unread",
        author: String? = nil,
        published: Date? = nil,
        now: Date = Date(),
        id: DocumentID = DocumentID(),
        existingPaths: Set<RelativePath> = []
    ) -> Output {
        let title = effectiveTitle(content.title)
        let path = destinationPath(title: title, now: now, existingPaths: existingPaths)
        let effectiveTags = mergedTags(tags)
        let effectiveAuthor = (author ?? content.byline)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let frontmatter = buildFrontmatter(
            id: id,
            now: now,
            title: title,
            content: content,
            author: (effectiveAuthor?.isEmpty ?? true) ? nil : effectiveAuthor,
            published: published,
            tags: effectiveTags,
            status: status,
            summaryModel: summaryModel,
            validatorIssueCount: validatorIssueCount,
            unresolvedCitationCount: summary.unresolvedCitationCount,
            summaryMarkdown: summary.markdown
        )

        let body = "# \(title)\n\n" + summary.markdown
        let markdown = frontmatter + "\n\n" + body

        return Output(markdown: markdown, path: path, title: title, tags: effectiveTags, id: id)
    }

    // MARK: - Path

    /// `Web/{YYYY-MM-DD}-{slug}.md`, numeric-suffixed on collision:
    /// `Web/{date}-{slug}-2.md`, `-3.md`, …
    static func destinationPath(title: String, now: Date, existingPaths: Set<RelativePath>) -> RelativePath {
        let datePrefix = dateFormatter.string(from: now)
        let slug = truncatedSlug(for: title)
        let base = "\(datePrefix)-\(slug)"

        var candidate = "\(folder)/\(base).md"
        var suffix = 2
        while existingPaths.contains(candidate) {
            candidate = "\(folder)/\(base)-\(suffix).md"
            suffix += 1
        }
        return candidate
    }

    /// A page-title slug capped at ``maxSlugLength``, trimmed back to the last
    /// full segment (no dangling trailing hyphen) if truncation lands mid-word.
    static func truncatedSlug(for title: String) -> String {
        let full = WebSlug.slug(for: title)
        guard full.count > maxSlugLength else { return full }
        var truncated = String(full.prefix(maxSlugLength))
        while truncated.hasSuffix("-") { truncated.removeLast() }
        return truncated.isEmpty ? "section" : truncated
    }

    private static func effectiveTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Tags

    /// `tags`, lowercased/trimmed, deduped, with ``baseTag`` always present
    /// (appended if not already there — first-occurrence order otherwise preserved).
    static func mergedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags + [baseTag] {
            let normalized = tag.trimmingCharacters(in: .whitespaces).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            out.append(normalized)
        }
        return out
    }

    // MARK: - Reading time

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Reading time at a conventional 200 words/minute, rounded up, minimum 1
    /// minute so an empty/near-empty summary never reads as "0 min".
    static func readingTimeMinutes(wordCount: Int) -> Int {
        max(1, Int((Double(wordCount) / 200.0).rounded(.up)))
    }

    // MARK: - Frontmatter

    private static func buildFrontmatter(
        id: DocumentID,
        now: Date,
        title: String,
        content: WebContent,
        author: String?,
        published: Date?,
        tags: [String],
        status: String,
        summaryModel: String,
        validatorIssueCount: Int,
        unresolvedCitationCount: Int,
        summaryMarkdown: String
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["---"]

        // Standard identity fields every PunkRecords note carries.
        lines.append("id: \(id.uuidString)")
        lines.append("created: \(iso.string(from: now))")
        lines.append("modified: \(iso.string(from: now))")

        // User-facing fields (PUNK-ddq schema order).
        lines.append("title: \(yamlQuoted(title))")
        lines.append("source_url: \(yamlQuoted(content.sourceURL.absoluteString))")
        lines.append("source_domain: \(yamlQuoted(content.sourceURL.host ?? ""))")
        if let author {
            lines.append("author: \(yamlQuoted(author))")
        }
        if let published {
            lines.append("published: \(yamlQuoted(iso.string(from: published)))")
        }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("type: web-summary")
        lines.append("status: \(yamlQuoted(status))")

        // Implementation details, namespaced so they read as "generated", not
        // user data.
        lines.append("_punkrecords:")
        lines.append("  fetched: \(yamlQuoted(iso.string(from: content.extractedAt)))")
        lines.append("  fetcher: \(yamlQuoted(content.tier.rawValue))")
        lines.append("  summary_model: \(yamlQuoted(summaryModel))")
        lines.append("  summary_prompt_version: \(yamlQuoted(WebSummaryPrompt.promptVersion))")
        let words = wordCount(in: summaryMarkdown)
        lines.append("  word_count: \(words)")
        lines.append("  reading_time_min: \(readingTimeMinutes(wordCount: words))")
        lines.append("  validator_issue_count: \(validatorIssueCount)")
        lines.append("  unresolved_citation_count: \(unresolvedCitationCount)")

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Double-quoted YAML scalar, escaping the characters that would otherwise
    /// break out of the quotes or corrupt the line: `\`, `"`, and embedded
    /// newlines/tabs. Safe for arbitrary titles (emoji, unicode, colons,
    /// quotes) since every other character passes through unescaped inside a
    /// YAML double-quoted string.
    static func yamlQuoted(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
