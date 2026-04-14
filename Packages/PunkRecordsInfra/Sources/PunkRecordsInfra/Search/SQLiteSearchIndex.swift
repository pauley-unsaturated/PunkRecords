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

    private nonisolated func migrateDatabaseIfNeeded() throws {
        try dbPool.write { db in
            // Document metadata
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_meta (
                    id          TEXT PRIMARY KEY,
                    path        TEXT NOT NULL,
                    title       TEXT,
                    created_at  INTEGER NOT NULL,
                    modified_at INTEGER NOT NULL,
                    tag_json    TEXT
                )
            """)

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
        }
    }

    // MARK: - SearchService

    public func search(query: String) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let parsed = SearchQueryParser.parse(query)

        return try await dbPool.read { db -> [SearchResult] in
            var results: [SearchResult] = []

            let ftsQuery = parsed.ftsQuery
            guard !ftsQuery.isEmpty else { return [] }

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

            // Apply tag filter if present
            if let tagFilter = parsed.tagFilter {
                let taggedIDs = try Row.fetchAll(db, sql: """
                    SELECT id FROM document_meta WHERE tag_json LIKE ?
                """, arguments: ["%\(tagFilter)%"])
                let taggedIDSet = Set(taggedIDs.compactMap { $0["id"] as? String })
                results = results.filter { taggedIDSet.contains($0.documentID.uuidString) }
            }

            return results
        }
    }

    public func index(document: Document) async throws {
        let bodyText = Self.stripFrontmatter(from: document.content)
        try await dbPool.write { db in
            // Upsert metadata
            try db.execute(sql: """
                INSERT OR REPLACE INTO document_meta (id, path, title, created_at, modified_at, tag_json)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                document.id.uuidString,
                document.path,
                document.title,
                Int(document.created.timeIntervalSince1970),
                Int(document.modified.timeIntervalSince1970),
                try? JSONEncoder().encode(document.tags).base64EncodedString()
            ])

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
            try db.execute(sql: "DELETE FROM document_fts WHERE id = ?", arguments: [idStr])
            try db.execute(sql: "DELETE FROM document_links WHERE source_id = ?", arguments: [idStr])
        }
    }

    public func rebuildIndex(documents: [Document]) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM document_meta")
            try db.execute(sql: "DELETE FROM document_fts")
            try db.execute(sql: "DELETE FROM document_links")
        }
        for doc in documents {
            try await index(document: doc)
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

    private static func stripFrontmatter(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                return Array(lines[(i + 1)...]).joined(separator: "\n")
            }
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
                // Tag filter: take the first word after the prefix
                let body = String(rawToken.dropFirst(4))
                if let firstWord = Self.splitIntoWords(body).first {
                    result.tagFilter = firstWord
                }
            } else if rawToken.hasPrefix("title:") {
                let body = String(rawToken.dropFirst(6))
                if let firstWord = Self.splitIntoWords(body).first {
                    result.titleFilter = firstWord
                }
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
