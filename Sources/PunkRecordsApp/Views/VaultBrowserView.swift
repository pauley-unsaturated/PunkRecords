import SwiftUI
import AppKit
import PunkRecordsCore

struct VaultBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var renamingDocumentPath: String?
    @State private var renameText: String = ""
    @State private var deleteCandidate: Document?
    @State private var showDeleteDialog = false

    @FocusState private var isSearchFocused: Bool

    private var isFiltering: Bool {
        !appState.sidebarFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var groupedByFolder: [SidebarFolderGroup] {
        SidebarFilter.filter(documents: appState.documents, query: appState.sidebarFilterQuery)
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            searchField
            Divider()

            List(selection: $appState.selectedDocumentPath) {
                if let vault = appState.currentVault {
                    Section(vault.name) {
                        if groupedByFolder.isEmpty && isFiltering {
                            Text("No matches")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(groupedByFolder) { group in
                                if group.folder.isEmpty {
                                    ForEach(group.documents) { doc in
                                        row(for: doc, vaultRoot: vault.rootURL)
                                    }
                                } else {
                                    folderDisclosure(group, vaultRoot: vault.rootURL)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onKeyPress(.return, action: handleReturnKey)
        .onChange(of: appState.selectedDocumentPath) { _, newPath in
            commitRenameOnSelectionChange(newPath: newPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowFocusSidebarSearch)) { _ in
            isSearchFocused = true
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

    // MARK: - Search field

    private var searchField: some View {
        @Bindable var appState = appState
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Filter", text: $appState.sidebarFilterQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityIdentifier("sidebarSearchField")
                .onKeyPress(.escape) {
                    if appState.sidebarFilterQuery.isEmpty {
                        isSearchFocused = false
                    } else {
                        appState.sidebarFilterQuery = ""
                    }
                    return .handled
                }
            if !appState.sidebarFilterQuery.isEmpty {
                Button {
                    appState.sidebarFilterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebarSearchClear")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    @ViewBuilder
    private func folderDisclosure(_ group: SidebarFolderGroup, vaultRoot: URL) -> some View {
        // When filtering, force every folder containing a match to stay
        // expanded so the matches are actually visible without an extra
        // click. When unfiltered, restore the default folded behavior.
        if isFiltering {
            DisclosureGroup(isExpanded: .constant(true)) {
                ForEach(group.documents) { doc in
                    row(for: doc, vaultRoot: vaultRoot)
                }
            } label: {
                folderLabel(group)
            }
        } else {
            DisclosureGroup {
                ForEach(group.documents) { doc in
                    row(for: doc, vaultRoot: vaultRoot)
                }
            } label: {
                folderLabel(group)
            }
        }
    }

    private func folderLabel(_ group: SidebarFolderGroup) -> some View {
        HStack {
            Text(group.folder)
            if isFiltering {
                Spacer()
                Text("\(group.hitCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(group.hitCount) matches")
            }
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

    // MARK: - Helpers (unchanged behavior)

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
