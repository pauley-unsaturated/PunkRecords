import Foundation
import PunkRecordsCore

/// Smart Notes glue on `AppState` (PUNK-ic6). All the query logic lives in
/// unit-tested Core (`SmartNoteQuery`, `SmartNoteEvaluator`, `SmartNoteFile`);
/// this layer only derives the saved smart notes from the open vault's document
/// list and writes new/edited ones back through the repository (mirroring the
/// `createNewNote` write path).
@MainActor
extension AppState {

    /// The user's saved smart notes, parsed from the `Smart Notes/*.md` files
    /// already loaded into `documents`. Files that don't parse as smart notes
    /// are skipped. Sorted by name.
    var smartNotes: [SmartNote] {
        documents
            .filter { SmartNoteFile.isSmartNotePath($0.path) }
            .compactMap { try? SmartNoteFile.parse($0.content) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Documents that satisfy `query`, excluding the smart-note files themselves
    /// (a smart note should surface real notes, not other saved searches).
    func smartNoteMatches(_ query: SmartNoteQuery) -> [SmartNoteMatch] {
        let candidates = documents.filter { !SmartNoteFile.isSmartNotePath($0.path) }
        return SmartNoteEvaluator.evaluate(query, documents: candidates)
    }

    /// Persist a new or edited smart note as `Smart Notes/{name}.md`. When
    /// `replacing` is supplied and its name changed, the old file is removed so a
    /// rename doesn't leave a stale copy.
    func saveSmartNote(name: String, query: SmartNoteQuery, replacing previous: SmartNote? = nil) async {
        guard let repo = repository else { return }
        let safe = FilenameHelpers.sanitizeFilename(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !safe.isEmpty else {
            errorMessage = "Give the smart note a name."
            return
        }

        let note = SmartNote(name: safe, query: query)
        let path = VaultPaths.smartNotePath(forName: safe)
        let content: String
        do {
            content = try SmartNoteFile.serialize(note)
        } catch {
            errorMessage = "Failed to encode smart note: \(error.localizedDescription)"
            return
        }

        let doc = Document(title: safe, content: content, path: path)
        do {
            try await repo.save(doc)
            if let previous {
                let oldPath = VaultPaths.smartNotePath(forName: previous.name)
                if oldPath != path, let oldDoc = documents.first(where: { $0.path == oldPath }) {
                    try? await repo.delete(oldDoc)
                    session.remove(path: oldPath)
                    if let index = searchIndex { try? await index.removeFromIndex(documentID: oldDoc.id) }
                }
            }
        } catch {
            errorMessage = "Failed to save smart note: \(error.localizedDescription)"
            return
        }

        session.upsert(doc)
        if let index = searchIndex { try? await index.index(document: doc) }
    }

    /// Delete a saved smart note's backing file.
    func deleteSmartNote(_ note: SmartNote) async {
        guard let repo = repository else { return }
        let path = VaultPaths.smartNotePath(forName: note.name)
        guard let doc = documents.first(where: { $0.path == path }) else { return }
        do {
            try await repo.delete(doc)
        } catch {
            errorMessage = "Failed to delete smart note: \(error.localizedDescription)"
            return
        }
        session.remove(path: path)
        if let index = searchIndex { try? await index.removeFromIndex(documentID: doc.id) }
    }
}
