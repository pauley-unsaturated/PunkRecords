import Foundation

/// A folder + its matching documents, with a hit count for the sparse-tree
/// sidebar UI. Folders with zero matches are dropped before this struct is
/// constructed, so `hitCount` is always > 0 in a filtered result and equals
/// `documents.count` in an unfiltered one.
public struct SidebarFolderGroup: Identifiable, Hashable, Sendable {
    public let folder: String
    public let documents: [Document]
    public let hitCount: Int

    public init(folder: String, documents: [Document], hitCount: Int) {
        self.folder = folder
        self.documents = documents
        self.hitCount = hitCount
    }

    public var id: String { folder }
}

/// Pure filtering logic for the sparse-tree sidebar. Lives in Core so it
/// can be unit-tested without standing up the SwiftUI view.
///
/// The model mirrors Xcode's Project Navigator filter: when the query is
/// non-empty, only documents whose title contains the query (case- and
/// diacritic-insensitive) survive, and folders without survivors are
/// dropped — but folders that DO have survivors stay in the tree even
/// if the folder name itself doesn't match, preserving hierarchical
/// context. An empty query returns every document grouped by folder.
public enum SidebarFilter {

    /// Filters and groups the given documents according to `query`.
    /// Returns folder groups sorted by folder name (empty folder = vault
    /// root, sorted first).
    public static func filter(
        documents: [Document],
        query: String
    ) -> [SidebarFolderGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmed.isEmpty

        var groups: [String: [Document]] = [:]
        for doc in documents {
            if isFiltering, !matches(doc, query: trimmed) { continue }
            let folder = (doc.path as NSString).deletingLastPathComponent
            groups[folder, default: []].append(doc)
        }

        return groups
            .map { folder, docs in
                SidebarFolderGroup(
                    folder: folder,
                    documents: docs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                    hitCount: docs.count
                )
            }
            .sorted { lhs, rhs in
                // Vault root (empty folder) sorts first, then alphabetical.
                if lhs.folder.isEmpty != rhs.folder.isEmpty { return lhs.folder.isEmpty }
                return lhs.folder.localizedStandardCompare(rhs.folder) == .orderedAscending
            }
    }

    /// Match against title (case- and diacritic-insensitive substring), or
    /// against tags when the query carries a `tag:` prefix.
    ///
    /// The `tag:` form powers click-to-filter from `#tag` pills in the editor:
    /// `tag:swift` keeps only notes tagged `swift`. A bare query still matches
    /// titles only — broader content/path search lives in the FTS5 index, not
    /// this navigation filter.
    private static func matches(_ doc: Document, query: String) -> Bool {
        if let tag = tagPrefix(in: query) {
            guard !tag.isEmpty else { return true }
            return doc.tags.contains { $0.range(of: tag, options: .caseInsensitive) != nil }
        }
        return doc.title.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// Extracts the tag from a `tag:<name>` query, or nil if absent.
    private static func tagPrefix(in query: String) -> String? {
        let prefix = "tag:"
        guard query.lowercased().hasPrefix(prefix) else { return nil }
        return String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
