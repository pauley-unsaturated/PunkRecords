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

    /// Substring match against title, case- and diacritic-insensitive.
    /// Tag and path matches are intentionally excluded here — those belong
    /// in the deeper FTS5-backed content search, not the navigation filter.
    private static func matches(_ doc: Document, query: String) -> Bool {
        doc.title.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}
