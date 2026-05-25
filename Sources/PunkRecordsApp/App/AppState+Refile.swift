import AppKit
import PunkRecordsCore
import PunkRecordsInfra

/// The heading the refile picker will move, captured when ⌘⇧M opens.
struct RefileSource: Equatable {
    let path: RelativePath
    let sectionRange: NSRange
    let headingTitle: String
    let headingPath: [String]
}

/// A destination shown in the refile picker: a heading in some note, or the end
/// of a note when `headingPath` is nil.
struct RefileTarget: Identifiable, Equatable {
    let id = UUID()
    let documentPath: RelativePath
    let documentTitle: String
    let headingPath: [String]?

    /// `File ▸ Heading ▸ Sub`, or `File ▸ (end of file)`.
    var displayPath: String {
        if let headingPath {
            return ([documentTitle] + headingPath).joined(separator: " ▸ ")
        }
        return "\(documentTitle) ▸ (end of file)"
    }
}

@MainActor
extension AppState {
    /// Open the refile picker, but only when the caret sits within a heading's
    /// section in the open document.
    func beginRefile() {
        guard let doc = selectedDocument else { return }
        let content = currentEditorContent(for: doc)
        let nodes = HeadingOutline.parse(content)
        // Deepest (innermost) heading whose section contains the caret.
        guard let node = nodes.last(where: { sectionContains(editorCaretLocation, $0.sectionRange) }) else {
            errorMessage = "Place the cursor on a heading to refile it."
            return
        }
        refileSource = RefileSource(
            path: doc.path,
            sectionRange: node.sectionRange,
            headingTitle: node.title,
            headingPath: node.path
        )
        isRefilePresented = true
    }

    /// All refile destinations: every note's end plus each heading, excluding
    /// the source heading and its own subtree (can't refile into itself).
    func refileTargets() -> [RefileTarget] {
        guard let source = refileSource else { return [] }
        let sorted = documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var targets: [RefileTarget] = []
        for doc in sorted {
            targets.append(RefileTarget(documentPath: doc.path, documentTitle: doc.title, headingPath: nil))
            for node in HeadingOutline.parse(currentEditorContent(for: doc)) {
                if doc.path == source.path, isWithin(node.sectionRange, source.sectionRange) { continue }
                targets.append(RefileTarget(documentPath: doc.path, documentTitle: doc.title, headingPath: node.path))
            }
        }
        return targets
    }

    /// How many `[[Note#Heading]]` links would change if this refile updates
    /// links — drives the confirmation dialog.
    func refileLinkImpact(to target: RefileTarget) -> Int {
        guard let source = refileSource,
              let sourceDoc = documents.first(where: { $0.path == source.path }),
              let destDoc = documents.first(where: { $0.path == target.documentPath }),
              sourceDoc.title.caseInsensitiveCompare(destDoc.title) != .orderedSame else { return 0 }
        let notes = documents.map { (title: $0.title, content: currentEditorContent(for: $0)) }
        return HeadingRefileLinks.rewriteHeadingLinks(
            in: notes,
            movingHeading: source.headingTitle,
            fromNote: sourceDoc.title,
            toNote: destDoc.title
        ).reduce(0) { $0 + $1.count }
    }

    /// Perform the refile: plan the rewrites, write them, and register undo.
    func performRefile(to target: RefileTarget, updateLinks: Bool) async {
        guard let repo = repository, let source = refileSource else { return }
        let notes = documents.map {
            RefilePlan.Note(path: $0.path, title: $0.title, content: currentEditorContent(for: $0))
        }
        let request = RefilePlan.Request(
            sourcePath: source.path,
            sectionRange: source.sectionRange,
            headingTitle: source.headingTitle,
            destPath: target.documentPath,
            targetHeadingPath: target.headingPath,
            updateLinks: updateLinks
        )
        guard let changes = RefilePlan.make(notes: notes, request) else {
            errorMessage = "Couldn't refile “\(source.headingTitle)”."
            return
        }

        let before: [(Document, String)] = changes.compactMap { change in
            documents.first { $0.path == change.path }.map { ($0, $0.content) }
        }
        await applyRefileChanges(changes, repo: repo)
        registerRefileUndo(restoring: before)
        refileSource = nil
    }

    // MARK: - Apply / undo

    private func applyRefileChanges(_ changes: [RefilePlan.Change], repo: FileSystemDocumentRepository) async {
        for change in changes {
            guard let existing = documents.first(where: { $0.path == change.path }) else { continue }
            let updated = rewritten(existing, content: change.newContent)
            do {
                try await repo.save(updated)
            } catch {
                errorMessage = "Failed to write \(change.path): \(error.localizedDescription)"
                continue
            }
            session.upsert(updated)
            if let index = searchIndex { try? await index.index(document: updated) }
        }
        editorReloadToken = UUID()
    }

    private func registerRefileUndo(restoring before: [(Document, String)]) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.restoreRefile(before) }
        }
        undoManager.setActionName("Refile Heading")
    }

    private func restoreRefile(_ before: [(Document, String)]) async {
        guard let repo = repository else { return }
        for (doc, oldContent) in before {
            let restored = rewritten(doc, content: oldContent)
            do {
                try await repo.save(restored)
            } catch {
                errorMessage = "Failed to undo refile for \(doc.path): \(error.localizedDescription)"
                continue
            }
            session.upsert(restored)
            if let index = searchIndex { try? await index.index(document: restored) }
        }
        editorReloadToken = UUID()
    }

    // MARK: - Helpers

    private func rewritten(_ doc: Document, content: String) -> Document {
        Document(
            id: doc.id,
            title: doc.title,
            content: content,
            path: doc.path,
            tags: doc.tags,
            created: doc.created,
            modified: Date(),
            frontmatter: doc.frontmatter,
            linkedDocumentIDs: doc.linkedDocumentIDs
        )
    }

    /// Live editor text for the open document, else the on-disk content.
    private func currentEditorContent(for doc: Document) -> String {
        if doc.path == selectedDocumentPath, !editorText.isEmpty { return editorText }
        return doc.content
    }

    private func sectionContains(_ caret: Int, _ range: NSRange) -> Bool {
        caret >= range.location && caret <= NSMaxRange(range)
    }

    /// True when `inner` is fully contained within `outer` (source + subtree).
    private func isWithin(_ inner: NSRange, _ outer: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}
