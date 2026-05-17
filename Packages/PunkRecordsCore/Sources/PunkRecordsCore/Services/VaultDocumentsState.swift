import Foundation

/// Pure-value snapshot of "the open vault's document list, and what the user has selected."
/// Lives in Core so it can be exercised directly by tests without dragging in SwiftUI,
/// FSEvents, or the App target. AppState wraps an instance of this and re-exposes it
/// to views.
public struct VaultDocumentsState: Sendable, Equatable {
    public var documents: [Document]
    /// Stable selection key. Path is unique on disk; ids may collide when frontmatter is duplicated.
    public var selectedPath: RelativePath?

    public init(documents: [Document] = [], selectedPath: RelativePath? = nil) {
        self.documents = documents
        self.selectedPath = selectedPath
    }

    public var selectedDocument: Document? {
        guard let selectedPath else { return nil }
        return documents.first { $0.path == selectedPath }
    }

    // MARK: - Mutations

    /// Insert-or-update a document. Matches by **path first** (path is unique on disk)
    /// and falls back to id (which can collide in vaults with duplicate frontmatter).
    /// New documents are appended.
    public mutating func upsert(_ doc: Document) {
        if let idx = documents.firstIndex(where: { $0.path == doc.path }) {
            documents[idx] = doc
        } else if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
    }

    /// Drop the document at this path, and clear `selectedPath` if it pointed there.
    public mutating func remove(path: RelativePath) {
        documents.removeAll { $0.path == path }
        if selectedPath == path {
            selectedPath = nil
        }
    }

    /// Apply a rename: remove the old path, upsert the renamed document, and follow
    /// the selection if it was on the renamed file. No-op for in-place renames where
    /// `oldPath == newDocument.path`.
    public mutating func applyRename(from oldPath: RelativePath, to newDocument: Document) {
        let pathChanged = oldPath != newDocument.path
        if pathChanged {
            documents.removeAll { $0.path == oldPath }
            if selectedPath == oldPath {
                selectedPath = newDocument.path
            }
        }
        upsert(newDocument)
    }

    /// Apply a single vault change event from the repository watcher.
    public mutating func apply(_ change: VaultChange) {
        switch change {
        case .added(let doc), .modified(let doc):
            upsert(doc)
        case .deleted(_, let path):
            remove(path: path)
        }
    }
}
