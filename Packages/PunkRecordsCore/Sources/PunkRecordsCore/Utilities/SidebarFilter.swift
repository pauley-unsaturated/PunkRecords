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

// MARK: - Recursive folder tree (PUNK-9y1)

/// A node in the sidebar's recursive folder tree. Mirrors the
/// ``ChatThreadHelpers/ThreadTreeNode`` precedent stylistically: an immutable
/// value with a stable `id` (the full folder path) and pre-sorted children, so
/// the SwiftUI view is a thin recursive shell over tested Core logic.
///
/// - `name` is the LAST path component — the label the sidebar renders.
/// - `path` is the full folder path relative to the vault root (also the `id`).
/// - `documents` are the documents that live DIRECTLY in this folder, already
///   title-sorted by ``SidebarFilter/filter(documents:query:)``.
/// - `children` are the subfolder nodes, sorted case-insensitively by name.
public struct SidebarFolderNode: Identifiable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let documents: [Document]
    public let children: [SidebarFolderNode]

    public init(
        name: String,
        path: String,
        documents: [Document],
        children: [SidebarFolderNode] = []
    ) {
        self.name = name
        self.path = path
        self.documents = documents
        self.children = children
    }

    public var id: String { path }

    /// Documents in this folder AND every descendant. Powers the filter badge,
    /// which now sums a whole subtree instead of a single flat folder.
    public var totalDocumentCount: Int {
        documents.count + children.reduce(0) { $0 + $1.totalDocumentCount }
    }
}

extension SidebarFilter {

    /// Assemble a strict recursive folder tree from the flat folder groups
    /// produced by ``filter(documents:query:)``.
    ///
    /// Building OVER GROUPS — rather than re-deriving straight from documents —
    /// is the cleaner seam: it reuses the group step's filtering (title / `tag:`
    /// matching, dropping folders with no survivors), folder extraction, and
    /// title sort, so grouping/sorting stays defined in exactly one place. The
    /// tree builder adds only the orthogonal concern the groups lack: nesting.
    ///
    /// The vault-root group (`folder == ""`) is intentionally EXCLUDED — root
    /// documents render flat above the tree, as they always have.
    ///
    /// Intermediate folders that hold no documents directly but do have
    /// descendants are SYNTHESIZED as nodes (empty `documents`), so a leaf-only
    /// path like `code/blackwork/node` still yields `code › blackwork › node`.
    /// Siblings at every level sort case-insensitively by name (localized), the
    /// same comparator ``filter(documents:query:)`` uses for folders.
    public static func folderTree(from groups: [SidebarFolderGroup]) -> [SidebarFolderNode] {
        // Documents that sit DIRECTLY in each folder path. Only folders that
        // actually contain (matching) documents appear as groups; ancestors are
        // synthesized below with no direct documents of their own.
        var documentsByPath: [String: [Document]] = [:]
        var allPaths: Set<String> = []

        for group in groups where !group.folder.isEmpty {
            documentsByPath[group.folder] = group.documents
            // Register the folder AND every ancestor prefix so a doc-less
            // intermediate folder still becomes a node.
            var prefix = group.folder
            while !prefix.isEmpty {
                allPaths.insert(prefix)
                prefix = (prefix as NSString).deletingLastPathComponent
            }
        }

        // Bucket every folder path under its parent ("" == the vault root / top
        // level of the tree).
        var childrenByParent: [String: [String]] = [:]
        for path in allPaths {
            let parent = (path as NSString).deletingLastPathComponent
            childrenByParent[parent, default: []].append(path)
        }

        func lastComponent(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }

        func build(_ path: String) -> SidebarFolderNode {
            let children = (childrenByParent[path] ?? [])
                .sorted { lastComponent($0).localizedStandardCompare(lastComponent($1)) == .orderedAscending }
                .map(build)
            return SidebarFolderNode(
                name: lastComponent(path),
                path: path,
                documents: documentsByPath[path] ?? [],
                children: children
            )
        }

        return (childrenByParent[""] ?? [])
            .sorted { lastComponent($0).localizedStandardCompare(lastComponent($1)) == .orderedAscending }
            .map(build)
    }
}
