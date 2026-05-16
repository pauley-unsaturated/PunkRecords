import SwiftUI
import AppKit
import PunkRecordsCore

struct VaultBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var renamingDocumentPath: String?
    @State private var renameText: String = ""
    @State private var deleteCandidate: Document?
    @State private var showDeleteDialog = false

    private var groupedByFolder: [FolderGroup] {
        var groups: [String: [Document]] = [:]
        for doc in appState.documents {
            let folder = (doc.path as NSString).deletingLastPathComponent
            groups[folder, default: []].append(doc)
        }
        return groups
            .map { FolderGroup(folder: $0.key, documents: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.folder < $1.folder }
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedDocumentPath) {
            if let vault = appState.currentVault {
                Section(vault.name) {
                    ForEach(groupedByFolder, id: \.folder) { group in
                        if group.folder.isEmpty {
                            ForEach(group.documents) { doc in
                                row(for: doc, vaultRoot: vault.rootURL)
                            }
                        } else {
                            DisclosureGroup(group.folder) {
                                ForEach(group.documents) { doc in
                                    row(for: doc, vaultRoot: vault.rootURL)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return, action: handleReturnKey)
        .onChange(of: appState.selectedDocumentPath) { _, newPath in
            commitRenameOnSelectionChange(newPath: newPath)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "plus") {
                    appState.createNewNote()
                }
            }
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: $showDeleteDialog,
            presenting: deleteCandidate
        ) { doc in
            Button("Move to Trash", role: .destructive) {
                Task { await appState.deleteDocument(doc) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will permanently remove the note from disk.")
        }
    }

    private func row(for doc: Document, vaultRoot: URL) -> some View {
        DocumentRow(
            document: doc,
            isRenaming: doc.path == renamingDocumentPath,
            renameText: $renameText,
            fileURL: vaultRoot.appendingPathComponent(doc.path),
            onBeginRename: { beginRename(doc) },
            onCommitRename: { commitRename(doc) },
            onCancelRename: cancelRename,
            onShowInFinder: { showInFinder(doc, vaultRoot: vaultRoot) },
            onRequestDelete: { requestDelete(doc) }
        )
    }

    private var deletePrompt: String {
        guard let doc = deleteCandidate else { return "" }
        return "Move “\(doc.title)” to the Trash?"
    }

    private func beginRename(_ doc: Document) {
        renameText = (doc.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        renamingDocumentPath = doc.path
    }

    private func commitRename(_ doc: Document) {
        let newTitle = renameText
        renamingDocumentPath = nil
        guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await appState.renameDocument(doc, to: newTitle) }
    }

    private func cancelRename() {
        renamingDocumentPath = nil
    }

    private func showInFinder(_ doc: Document, vaultRoot: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([vaultRoot.appendingPathComponent(doc.path)])
    }

    private func requestDelete(_ doc: Document) {
        deleteCandidate = doc
        showDeleteDialog = true
    }

    private func handleReturnKey() -> KeyPress.Result {
        guard renamingDocumentPath == nil,
              let path = appState.selectedDocumentPath,
              let doc = appState.documents.first(where: { $0.path == path }) else {
            return .ignored
        }
        beginRename(doc)
        return .handled
    }

    /// When the user clicks a different row mid-rename, commit the in-flight edit —
    /// matches Finder/Mail/Xcode "focus-loss commits" behavior.
    private func commitRenameOnSelectionChange(newPath: RelativePath?) {
        guard let renamingPath = renamingDocumentPath,
              newPath != renamingPath,
              let doc = appState.documents.first(where: { $0.path == renamingPath }) else { return }
        commitRename(doc)
    }
}

#Preview("Vault Browser") {
    VaultBrowserView()
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 250, height: 400)
}

private struct FolderGroup: Identifiable {
    let folder: String
    let documents: [Document]
    var id: String { folder }
}
