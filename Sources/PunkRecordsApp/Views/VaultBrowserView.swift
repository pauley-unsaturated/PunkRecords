import SwiftUI
import AppKit
import PunkRecordsCore

struct VaultBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var renamingDocumentPath: String?
    @State private var renameText: String = ""
    @State private var deleteCandidate: Document?
    @State private var showDeleteDialog = false

    // Chats section (PUNK-9ss)
    @State private var chatsExpanded = true
    @State private var threadPendingDeletion: ThreadSummary?
    @State private var showThreadDeleteDialog = false

    @FocusState private var isSearchFocused: Bool

    private var isFiltering: Bool {
        !appState.sidebarFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var groupedByFolder: [SidebarFolderGroup] {
        SidebarFilter.filter(documents: appState.documents, query: appState.sidebarFilterQuery)
    }

    /// The sidebar Chats tree, assembled from the shared controller's summaries by
    /// the pure ``ChatThreadHelpers/threadTree(from:)`` (nesting, orphan/cycle
    /// safety, newest-first sort). Empty until the controller loads.
    private var threadTree: [ChatThreadHelpers.ThreadTreeNode] {
        ChatThreadHelpers.threadTree(from: appState.chatController?.threadSummaries ?? [])
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

                    chatsSection
                }
            }
            .listStyle(.sidebar)
        }
        .task(id: appState.currentVault?.rootURL) {
            await appState.loadChatThreadsIfNeeded()
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
        .confirmationDialog(
            threadDeletePrompt,
            isPresented: $showThreadDeleteDialog,
            presenting: threadPendingDeletion
        ) { summary in
            Button("Delete Chat", role: .destructive) {
                Task { await appState.deleteChatThread(id: summary.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This conversation will be permanently deleted. This can't be undone.")
        }
    }

    // MARK: - Chats section (PUNK-9ss)

    /// Collapsible "Chats" section below the notes tree: forked-thread nesting,
    /// focus-note subtitles, active-thread highlight, per-row delete, and a New
    /// Chat (+) button in the header. Tree assembly + sort is the pure, tested
    /// ``ChatThreadHelpers/threadTree(from:)``; this is a thin shell over it.
    @ViewBuilder
    private var chatsSection: some View {
        Section(isExpanded: $chatsExpanded) {
            if threadTree.isEmpty {
                Text("No chats yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(threadTree) { node in
                    ThreadTreeRow(
                        node: node,
                        activeThreadID: appState.chatController?.activeThread?.id,
                        onSelect: { id in Task { await appState.openChatThread(id: id) } },
                        onDelete: { summary in
                            threadPendingDeletion = summary
                            showThreadDeleteDialog = true
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text("Chats")
                Spacer()
                Button {
                    appState.startNewChatThread()
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Start a new chat")
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("sidebarNewChatButton")
            }
        }
        .accessibilityIdentifier("sidebarThreadsSection")
    }

    private var threadDeletePrompt: String {
        guard let summary = threadPendingDeletion else { return "" }
        return "Delete “\(summary.title)”?"
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

// MARK: - Thread tree row

/// One row in the sidebar Chats tree (PUNK-9ss): a saved conversation shown as
/// title + relative updated date + optional focus-note subtitle, with forked
/// children nested under a `DisclosureGroup`. Recursive: a node renders its
/// children as further `ThreadTreeRow`s. Pure presentation over the
/// Core-assembled ``ChatThreadHelpers/ThreadTreeNode`` — no store access here.
private struct ThreadTreeRow: View {
    let node: ChatThreadHelpers.ThreadTreeNode
    let activeThreadID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (ThreadSummary) -> Void

    var body: some View {
        if node.children.isEmpty {
            rowLabel
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    ThreadTreeRow(
                        node: child,
                        activeThreadID: activeThreadID,
                        onSelect: onSelect,
                        onDelete: onDelete
                    )
                }
            } label: {
                rowLabel
            }
        }
    }

    private var isActive: Bool { node.summary.id == activeThreadID }

    private var rowLabel: some View {
        Button {
            onSelect(node.summary.id)
        } label: {
            HStack(spacing: 6) {
                // Active-thread indicator (also the accessibility distinction).
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .opacity(isActive ? 1 : 0)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.summary.title)
                        .lineLimit(1)
                        .fontWeight(isActive ? .semibold : .regular)

                    HStack(spacing: 4) {
                        Text(node.summary.updatedAt, format: .relative(presentation: .named))
                        if let focus = node.summary.focusNote {
                            Image(systemName: "doc.text")
                            Text(focus.title).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebarThreadRow")
        .accessibilityLabel(node.summary.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            Button(role: .destructive) {
                onDelete(node.summary)
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        }
    }
}

#Preview("Vault Browser") {
    VaultBrowserView()
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 250, height: 400)
}
