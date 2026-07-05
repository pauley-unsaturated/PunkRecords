import Foundation
import PunkRecordsCore

/// File-backed ``CrashRecoveryStore``. Persists unsaved-edit sidecars under
/// `{vault}/.punkrecords/recovery/` and reads them back for the launch-time
/// recovery scan. All mutating paths use write-then-atomic-rename so a crash
/// mid-write never leaves a torn sidecar (see ``CrashRecoveryStore`` for the
/// iCloud-sync interaction note).
public actor FileSystemCrashRecoveryStore: CrashRecoveryStore {
    private let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot.standardizedFileURL
    }

    private var recoveryDirURL: URL {
        vaultRoot.appendingPathComponent(VaultPaths.recoveryDirectory)
    }

    private func sidecarURL(forNoteID id: DocumentID) -> URL {
        vaultRoot.appendingPathComponent(VaultPaths.recoverySidecarPath(forNoteID: id))
    }

    // MARK: - CrashRecoveryStore

    public func writeSidecar(noteID: DocumentID, content: String) async throws {
        let dir = recoveryDirURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let target = sidecarURL(forNoteID: noteID)

        // Write-then-atomic-rename. Stage the bytes in a sibling temp file
        // (same directory ⇒ same filesystem ⇒ rename is a cheap, atomic
        // operation), then swap it into place. A crash before the swap leaves
        // only the temp behind (skipped by loadSidecars, since it isn't a
        // `{uuid}.md` name); a crash after leaves a fully-written sidecar.
        let temp = dir.appendingPathComponent("\(noteID.uuidString).\(UUID().uuidString).tmp")
        try content.write(to: temp, atomically: false, encoding: .utf8)
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            // Best-effort cleanup so a failed swap doesn't accumulate temps.
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    public func removeSidecar(noteID: DocumentID) async throws {
        let target = sidecarURL(forNoteID: noteID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        try fm.removeItem(at: target)
    }

    public func loadSidecars() async throws -> [RecoverySidecar] {
        let dir = recoveryDirURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var sidecars: [RecoverySidecar] = []
        for url in entries {
            guard let noteID = VaultPaths.recoveryNoteID(fromSidecarFilename: url.lastPathComponent) else {
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let modified = (attrs?[.modificationDate] as? Date) ?? Date()
            sidecars.append(
                RecoverySidecar(noteID: noteID, content: content, modified: modified)
            )
        }
        return sidecars
    }
}
