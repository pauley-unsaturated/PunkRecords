import AppKit
import PunkRecordsCore
import PunkRecordsInfra

/// The metadata-inspector (⌘I) glue on `AppState`. The panel is a thin shell;
/// all the parse/serialize/surgery logic lives in Core (`PropsBlock`,
/// `HeadingProps`, `NaturalDateParser`) and is unit-tested there. This layer
/// only threads the live editor text/caret into those pure functions and writes
/// the result back through the repository (mirroring the refile write path).
@MainActor
extension AppState {
    /// The inspector's current binding: the heading under the caret in the open
    /// document, or the document root when the caret sits above the first
    /// heading. `nil` when no note is open. Recomputed from `editorText` +
    /// `editorCaretLocation`, so moving the caret updates the inspector live.
    var inspectorTarget: HeadingPropsTarget? {
        guard let doc = selectedDocument else { return nil }
        return HeadingProps.target(forCaret: editorCaretLocation, in: inspectorEditorContent(for: doc))
    }

    /// A stable identity for the current target, so the panel can reload its
    /// draft when the caret moves to a different heading (or note).
    var inspectorTargetKey: String {
        switch inspectorTarget {
        case .none:
            return "none"
        case .documentRoot:
            return "root:\(selectedDocumentPath ?? "")"
        case .heading(let node):
            return "heading:\(selectedDocumentPath ?? ""):\(node.headingRange.location):\(node.title)"
        }
    }

    /// The heading title (or note title at the root) the inspector is editing.
    var inspectorTargetTitle: String {
        switch inspectorTarget {
        case .heading(let node):
            return node.title.isEmpty ? "Untitled Heading" : node.title
        case .documentRoot:
            return selectedDocument?.title ?? "Document"
        case .none:
            return "No Note"
        }
    }

    /// Breadcrumb path for the current target, e.g. `Guide ▸ Setup`.
    var inspectorTargetPath: String {
        switch inspectorTarget {
        case .heading(let node):
            return node.path.joined(separator: " ▸ ")
        case .documentRoot:
            return "Document metadata"
        case .none:
            return ""
        }
    }

    /// Whether the inspector is editing document-root frontmatter.
    var inspectorTargetIsRoot: Bool {
        if case .documentRoot = inspectorTarget { return true }
        return false
    }

    /// The props currently stored for the inspector's target.
    func currentProps() -> PropsBlock {
        guard let doc = selectedDocument, let target = inspectorTarget else { return PropsBlock() }
        return HeadingProps.read(from: inspectorEditorContent(for: doc), target: target)
    }

    /// Write `block` to the inspector's target: rewrite the open document,
    /// persist it, refresh search + session, register undo, and reload the
    /// editor so the callout/frontmatter change becomes visible.
    func applyProps(_ block: PropsBlock) async {
        guard let repo = repository, let doc = selectedDocument, let target = inspectorTarget else { return }
        let content = inspectorEditorContent(for: doc)
        let newContent = HeadingProps.apply(block, to: content, target: target)
        guard newContent != content else { return }

        let before = doc.content
        let updated = inspectorRewritten(doc, content: newContent)
        do {
            try await repo.save(updated)
        } catch {
            errorMessage = "Failed to update metadata: \(error.localizedDescription)"
            return
        }
        session.upsert(updated)
        if let index = searchIndex { try? await index.index(document: updated) }
        editorText = newContent
        editorReloadToken = UUID()
        registerInspectorUndo(path: doc.path, restoring: before)
    }

    // MARK: - Undo

    private func registerInspectorUndo(path: RelativePath, restoring before: String) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.restoreInspectorEdit(path: path, content: before) }
        }
        undoManager.setActionName("Edit Metadata")
    }

    private func restoreInspectorEdit(path: RelativePath, content: String) async {
        guard let repo = repository, let doc = documents.first(where: { $0.path == path }) else { return }
        let restored = inspectorRewritten(doc, content: content)
        do {
            try await repo.save(restored)
        } catch {
            errorMessage = "Failed to undo metadata edit: \(error.localizedDescription)"
            return
        }
        session.upsert(restored)
        if let index = searchIndex { try? await index.index(document: restored) }
        editorText = content
        editorReloadToken = UUID()
    }

    // MARK: - Helpers

    /// Live editor text for the open document, else its on-disk content —
    /// so the inspector reads and edits exactly what's on screen.
    private func inspectorEditorContent(for doc: Document) -> String {
        if doc.path == selectedDocumentPath, !editorText.isEmpty { return editorText }
        return doc.content
    }

    /// A copy of `doc` with new content and a refreshed title/tags/frontmatter
    /// (so a frontmatter edit updates the sidebar/search immediately, ahead of
    /// the FS watcher).
    private func inspectorRewritten(_ doc: Document, content: String) -> Document {
        let parsed = MarkdownParser().parse(
            content: content,
            filename: (doc.path as NSString).lastPathComponent
        )
        return Document(
            id: doc.id,
            title: parsed.title,
            content: content,
            path: doc.path,
            tags: parsed.tags,
            created: doc.created,
            modified: Date(),
            frontmatter: parsed.frontmatter,
            linkedDocumentIDs: doc.linkedDocumentIDs
        )
    }
}
