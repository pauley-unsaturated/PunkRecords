import Foundation
import GRDB
import PunkRecordsCore

/// FTS5-based full-text search index backed by SQLite via GRDB.
/// This is an index only — all source data lives in .md files.
public actor SQLiteSearchIndex: SearchService {
    private let dbPool: DatabasePool
    private let vaultRoot: URL

    public init(vaultRoot: URL) throws {
        self.vaultRoot = vaultRoot
        let dbDir = vaultRoot.appendingPathComponent(".punkrecords")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let dbPath = dbDir.appendingPathComponent("index.sqlite").path
        dbPool = try DatabasePool(path: dbPath)

        try migrateDatabaseIfNeeded()
    }

    /// Creates a temporary file-backed index for testing.
    public init(inMemory: Bool) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "PunkRecords-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.vaultRoot = tempDir
        dbPool = try DatabasePool(path: tempDir.appending(path: "index.sqlite").path)
        try migrateDatabaseIfNeeded()
    }

    /// Schema version for the derived on-disk index. Bump this whenever the
    /// table layout changes so a stale `.punkrecords/index.sqlite` is dropped
    /// and rebuilt cleanly on open rather than half-migrating. The index holds
    /// no source-of-truth data — it is rebuilt from the `.md` files on every
    /// vault open (see `AppState.openVault` → `rebuildIndex`) — so dropping it
    /// is always safe.
    ///
    /// History:
    ///   1 — original layout (tags stored base64-encoded JSON in
    ///       `document_meta.tag_json`, queried incoherently with `LIKE`)
    ///   2 — normalized `document_tags(doc_id, tag)` table for exact `tag:`
    ///       filtering; `tag_json` column removed
    private static let schemaVersion = 2

    private nonisolated func migrateDatabaseIfNeeded() throws {
        try dbPool.write { db in
            // `PRAGMA user_version` is SQLite's built-in schema-version slot.
            // The value is a compile-time constant (never user input), so
            // interpolating it is safe.
            let existingVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if existingVersion != Self.schemaVersion {
                // Prior-schema tables get dropped so we recreate cleanly. Safe
                // because the index is derived data, rebuilt after open.
                try db.execute(sql: "DROP TABLE IF EXISTS document_meta")
                try db.execute(sql: "DROP TABLE IF EXISTS document_fts")
                try db.execute(sql: "DROP TABLE IF EXISTS document_links")
                try db.execute(sql: "DROP TABLE IF EXISTS document_tags")
            }

            // Document metadata
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_meta (
                    id          TEXT PRIMARY KEY,
                    path        TEXT NOT NULL,
                    title       TEXT,
                    created_at  INTEGER NOT NULL,
                    modified_at INTEGER NOT NULL
                )
            """)

            // Normalized tag table: one row per (document, tag). Exact-token
            // matching via a bound `tag = ?` powers the `tag:` filter without
            // the substring false-positives a LIKE against joined tag text
            // would produce (e.g. `tag:swift` matching "swiftui"), and stays
            // injection-safe for punctuation-laden tags.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_tags (
                    doc_id  TEXT NOT NULL,
                    tag     TEXT NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tags_tag ON document_tags(tag)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tags_doc ON document_tags(doc_id)")

            // FTS5 full-text search
            if try !db.tableExists("document_fts") {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE document_fts USING fts5(
                        id UNINDEXED,
                        title,
                        body,
                        tags,
                        tokenize = 'porter ascii'
                    )
                """)
            }

            // Link graph
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_links (
                    source_id   TEXT NOT NULL,
                    target_id   TEXT,
                    target_path TEXT,
                    link_text   TEXT
                )
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_links_source ON document_links(source_id)
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_links_target ON document_links(target_id)
            """)

            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: - SearchService

    public func search(query: String) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let parsed = SearchQueryParser.parse(query)

        return try await dbPool.read { db -> [SearchResult] in
            // Resolve each metadata filter to a set of candidate document IDs.
            // `nil` means the filter is absent; an empty set means present but
            // matching nothing. All lookups use bound parameters.
            let tagIDs = try parsed.tagFilter.map { try Self.tagMatchIDs(db, tag: $0) }
            let titleIDs = try parsed.titleFilter.map { try Self.titleMatchIDs(db, title: $0) }

            func passesFilters(_ id: String) -> Bool {
                if let tagIDs, !tagIDs.contains(id) { return false }
                if let titleIDs, !titleIDs.contains(id) { return false }
                return true
            }

            let ftsQuery = parsed.ftsQuery
            if ftsQuery.isEmpty {
                // Metadata-only query (e.g. `tag:swift` or `title:Guide` with no
                // free-text terms). With no filter at all there is nothing to
                // rank, so return empty. Otherwise intersect the present filters.
                guard tagIDs != nil || titleIDs != nil else { return [] }
                var candidateIDs = tagIDs ?? titleIDs ?? []
                if let tagIDs, let titleIDs { candidateIDs = tagIDs.intersection(titleIDs) }
                guard !candidateIDs.isEmpty else { return [] }
                return try Self.metadataResults(db, ids: candidateIDs)
            }

            var results: [SearchResult] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    document_fts.id,
                    document_fts.title,
                    document_meta.path as path,
                    snippet(document_fts, 2, '<mark>', '</mark>', '...', 32) as excerpt,
                    bm25(document_fts) as rank
                FROM document_fts
                LEFT JOIN document_meta ON document_fts.id = document_meta.id
                WHERE document_fts MATCH ?
                ORDER BY rank
                LIMIT 50
            """, arguments: [ftsQuery])

            for row in rows {
                guard let idString = row["id"] as? String,
                      let id = UUID(uuidString: idString) else { continue }
                results.append(SearchResult(
                    documentID: id,
                    title: row["title"] as? String ?? "",
                    path: row["path"] as? String ?? "",
                    excerpt: row["excerpt"] as? String ?? "",
                    score: abs(row["rank"] as? Float ?? 0) // bm25 returns negative scores
                ))
            }

            // Narrow full-text hits by any metadata filters.
            if tagIDs != nil || titleIDs != nil {
                results = results.filter { passesFilters($0.documentID.uuidString) }
            }

            return results
        }
    }

    /// Document IDs carrying an exact tag match (case/whitespace-normalized).
    private static func tagMatchIDs(_ db: Database, tag: String) throws -> Set<String> {
        let normalized = normalizeTag(tag)
        guard !normalized.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT doc_id FROM document_tags WHERE tag = ?
        """, arguments: [normalized])
        return Set(rows.compactMap { $0["doc_id"] as? String })
    }

    /// Document IDs whose title contains `title` (case-insensitive substring).
    /// Substring — not prefix — matches the search-box mental model of "title
    /// contains X". LIKE metacharacters in the user's text are escaped so they
    /// match literally, and the pattern is passed as a bound parameter.
    private static func titleMatchIDs(_ db: Database, title: String) throws -> Set<String> {
        let needle = title.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let pattern = "%\(escapeLikePattern(needle))%"
        let rows = try Row.fetchAll(db, sql: """
            SELECT id FROM document_meta WHERE LOWER(title) LIKE ? ESCAPE '\\'
        """, arguments: [pattern])
        return Set(rows.compactMap { $0["id"] as? String })
    }

    /// Builds bare `SearchResult`s (no excerpt/score) from `document_meta` for a
    /// set of IDs — used when a query has only metadata filters and no FTS terms.
    private static func metadataResults(_ db: Database, ids: Set<String>) throws -> [SearchResult] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, title, path FROM document_meta")
        var results: [SearchResult] = []
        for row in rows {
            guard let idString = row["id"] as? String, ids.contains(idString),
                  let id = UUID(uuidString: idString) else { continue }
            results.append(SearchResult(
                documentID: id,
                title: row["title"] as? String ?? "",
                path: row["path"] as? String ?? "",
                excerpt: "",
                score: 0
            ))
        }
        return results
    }

    public func index(document: Document) async throws {
        let bodyText = Self.stripFrontmatter(from: document.content)
        try await dbPool.write { db in
            // Upsert metadata
            try db.execute(sql: """
                INSERT OR REPLACE INTO document_meta (id, path, title, created_at, modified_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                document.id.uuidString,
                document.path,
                document.title,
                Int(document.created.timeIntervalSince1970),
                Int(document.modified.timeIntervalSince1970)
            ])

            // Refresh normalized tags for this document (one queryable row per
            // distinct tag). Normalizing at the storage boundary keeps writes
            // consistent regardless of how the Document was constructed.
            try db.execute(sql: "DELETE FROM document_tags WHERE doc_id = ?",
                           arguments: [document.id.uuidString])
            var seenTags = Set<String>()
            for tag in document.tags {
                let normalized = Self.normalizeTag(tag)
                guard !normalized.isEmpty, seenTags.insert(normalized).inserted else { continue }
                try db.execute(sql: "INSERT INTO document_tags (doc_id, tag) VALUES (?, ?)",
                               arguments: [document.id.uuidString, normalized])
            }

            // Remove old FTS entry
            try db.execute(sql: "DELETE FROM document_fts WHERE id = ?",
                           arguments: [document.id.uuidString])

            // Insert FTS entry
            let bodyText = bodyText
            try db.execute(sql: """
                INSERT INTO document_fts (id, title, body, tags)
                VALUES (?, ?, ?, ?)
            """, arguments: [
                document.id.uuidString,
                document.title,
                bodyText,
                document.tags.joined(separator: " ")
            ])

            // Update links
            try db.execute(sql: "DELETE FROM document_links WHERE source_id = ?",
                           arguments: [document.id.uuidString])
            for linkedID in document.linkedDocumentIDs {
                try db.execute(sql: """
                    INSERT INTO document_links (source_id, target_id)
                    VALUES (?, ?)
                """, arguments: [document.id.uuidString, linkedID.uuidString])
            }
        }
    }

    public func removeFromIndex(documentID: DocumentID) async throws {
        try await dbPool.write { db in
            let idStr = documentID.uuidString
            try db.execute(sql: "DELETE FROM document_meta WHERE id = ?", arguments: [idStr])
            try db.execute(sql: "DELETE FROM document_tags WHERE doc_id = ?", arguments: [idStr])
            try db.execute(sql: "DELETE FROM document_fts WHERE id = ?", arguments: [idStr])
            try db.execute(sql: "DELETE FROM document_links WHERE source_id = ?", arguments: [idStr])
        }
    }

    public func rebuildIndex(documents: [Document]) async throws {
        try await rebuildIndex(documents: documents, onProgress: nil)
    }

    /// Like ``rebuildIndex(documents:)``, but reports indexing progress as
    /// `(completed, total)` so a vault open can show a determinate bar.
    /// `onProgress` is invoked on this actor: once with `(0, total)` before the
    /// first note, then after each note is indexed, ending at `(total, total)`.
    public func rebuildIndex(
        documents: [Document],
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM document_meta")
            try db.execute(sql: "DELETE FROM document_tags")
            try db.execute(sql: "DELETE FROM document_fts")
            try db.execute(sql: "DELETE FROM document_links")
        }
        let total = documents.count
        onProgress?(0, total)
        for (offset, doc) in documents.enumerated() {
            try await index(document: doc)
            onProgress?(offset + 1, total)
        }
    }

    public func backlinks(for documentID: DocumentID) async throws -> [DocumentID] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_id FROM document_links WHERE target_id = ?
            """, arguments: [documentID.uuidString])
            return rows.compactMap { row in
                guard let idStr = row["source_id"] as? String else { return nil }
                return UUID(uuidString: idStr)
            }
        }
    }

    // MARK: - Private

    /// Canonical tag form for both storage and lookup: lowercased and
    /// whitespace-trimmed. Interior characters (hyphens, dots, `+`, etc.) are
    /// preserved so hyphenated tags like `swift-concurrency` round-trip.
    private static func normalizeTag(_ tag: String) -> String {
        tag.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Escapes SQL LIKE metacharacters (`\`, `%`, `_`) so a user's substring
    /// filter matches literally. Pair with `ESCAPE '\'` in the query. This is
    /// belt-and-suspenders on top of parameter binding: binding already blocks
    /// injection; escaping additionally stops `%`/`_` from acting as wildcards.
    private static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func stripFrontmatter(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return Array(lines[(i + 1)...]).joined(separator: "\n")
        }
        return content
    }
}

// MARK: - Search Query Parser

struct SearchQueryParser {
    struct ParsedQuery {
        var terms: [String] = []
        var phrases: [String] = []
        var excludedTerms: [String] = []
        var tagFilter: String?
        var titleFilter: String?

        var ftsQuery: String {
            var parts: [String] = []
            parts.append(contentsOf: terms.map { Self.sanitizeFTSTerm($0) }.filter { !$0.isEmpty })
            parts.append(contentsOf: phrases.compactMap {
                let clean = Self.sanitizeFTSTerm($0)
                return clean.isEmpty ? nil : "\"\(clean)\""
            })
            for excluded in excludedTerms {
                let clean = Self.sanitizeFTSTerm(excluded)
                if !clean.isEmpty { parts.append("NOT \(clean)") }
            }
            return parts.joined(separator: " ")
        }

        /// FTS5 only accepts alphanumeric + underscore in unquoted terms. Everything
        /// else is either an operator or a syntax error. Whitelist for defense in depth
        /// (the parser should already split on non-word characters, but this ensures
        /// nothing unexpected reaches FTS5).
        fileprivate static func sanitizeFTSTerm(_ term: String) -> String {
            let allowed = CharacterSet.alphanumerics
                .union(.whitespaces)
                .union(CharacterSet(charactersIn: "_"))
            return term.unicodeScalars
                .filter { allowed.contains($0) }
                .map { String($0) }
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }

    static func parse(_ query: String) -> ParsedQuery {
        var result = ParsedQuery()
        var remaining = query

        // Extract quoted phrases first so internal punctuation is preserved
        let phrasePattern = #""([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: phrasePattern) {
            let matches = regex.matches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2,
                   let range = Range(match.range(at: 1), in: remaining) {
                    result.phrases.append(String(remaining[range]))
                }
                if let fullRange = Range(match.range, in: remaining) {
                    remaining.removeSubrange(fullRange)
                }
            }
        }

        // Tokenize on whitespace to detect operator prefixes (-, tag:, title:)
        let rawTokens = remaining.split(separator: " ").map(String.init)
        for rawToken in rawTokens {
            if rawToken.hasPrefix("-") {
                // Excluded: split remainder on non-word characters so punctuation doesn't leak through
                let body = String(rawToken.dropFirst())
                result.excludedTerms.append(contentsOf: Self.splitIntoWords(body))
            } else if rawToken.hasPrefix("tag:") {
                // Tag filter: keep the whole remaining token verbatim (minus
                // surrounding whitespace) so hyphenated/dotted tags like
                // `swift-concurrency` survive. The index matches it exactly
                // against the normalized tag table via a bound parameter, so no
                // FTS sanitization is needed or wanted here.
                let body = String(rawToken.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { result.tagFilter = body }
            } else if rawToken.hasPrefix("title:") {
                // Title filter: keep the whole remaining token so multi-part
                // titles like `my-note` aren't truncated to `my`. Matched as a
                // case-insensitive substring via a bound, LIKE-escaped parameter.
                let body = String(rawToken.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { result.titleFilter = body }
            } else {
                // Plain term: split on non-word boundaries so "KNOWLEDGE-BASE.md,"
                // yields ["KNOWLEDGE", "BASE", "md"] instead of one unsearchable blob.
                result.terms.append(contentsOf: Self.splitIntoWords(rawToken))
            }
        }

        return result
    }

    /// Split a string into alphanumeric-only words, treating punctuation as word boundaries.
    /// This is what lets us safely accept LLM-generated queries containing file paths, commas,
    /// periods, and other characters that FTS5 rejects.
    private static func splitIntoWords(_ s: String) -> [String] {
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.unicodeScalars
            .split { !wordChars.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
            .filter { !$0.isEmpty }
    }
}
