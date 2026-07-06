import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Root application state. Owns the dependency container and top-level UI state.
@MainActor
@Observable
final class AppState {
    var currentVault: Vault?
    var isSearchPresented = false
    var isQuickOpenPresented = false
    var isChatPanelVisible = false
    var isBacklinksPanelVisible = true
    var isLoading = false
    /// Progress of the in-flight vault open, driving the loading overlay.
    /// `nil` before the heavy work starts and once the vault is ready.
    var openProgress: VaultOpenProgress?
    var errorMessage: String?
    var askAIText: String?
    var selectedText: String?

    // MARK: - Refile (⌘⇧M)

    /// Live text + caret of the open editor, reported on every edit/selection so
    /// refile operates on what's actually on screen (not a stale session copy).
    var editorText: String = ""
    var editorCaretLocation: Int = 0
    /// The heading the refile picker will move, captured when ⌘⇧M opens it.
    var refileSource: RefileSource?
    var isRefilePresented = false
    /// Bumped after a refile writes the open document so the editor reloads.
    var editorReloadToken = UUID()

    /// Sidebar navigation filter. Shared here (rather than local to the sidebar
    /// view) so the editor can drive it — clicking a `#tag` pill sets it to
    /// `tag:<name>` to filter the note list. See `SidebarFilter`.
    var sidebarFilterQuery: String = ""

    /// Documents + selection live here. Operations on this state are Core-defined
    /// and exercised by tests directly — AppState just owns the snapshot.
    var session = VaultDocumentsState()

    /// Authoritative document list for the open vault. Mirrors the disk via the FS watcher.
    var documents: [Document] {
        get { session.documents }
        set { session.documents = newValue }
    }

    /// Stable selection key. Path is unique on disk; document ids may collide
    /// when vaults have duplicate frontmatter.
    var selectedDocumentPath: RelativePath? {
        get { session.selectedPath }
        set { session.selectedPath = newValue }
    }

    /// The currently selected document, resolved from `selectedDocumentPath`.
    var selectedDocument: Document? { session.selectedDocument }

    /// Distinct tags across the vault (lowercased at the Document boundary),
    /// sorted. Backs `#` autocomplete in the editor.
    var distinctTags: [String] {
        Array(Set(documents.flatMap(\.tags)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Dependencies — initialized lazily when a vault is opened
    private(set) var repository: FileSystemDocumentRepository?
    private(set) var searchIndex: SQLiteSearchIndex?
    private(set) var noteCompiler: NoteCompiler?
    private(set) var recoveryStore: FileSystemCrashRecoveryStore?
    private(set) var keychainService = KeychainService()

    /// The single shared chat controller for this vault (PUNK-9ss). Owned here
    /// (rather than by `LLMChatPanel`) so the sidebar Chats section and the chat
    /// panel read ONE source of truth — the same thread store, migration, active
    /// thread, and summaries — instead of each spinning up its own. Created when
    /// the vault opens; `nil` before then. Selecting a thread from the sidebar
    /// drives it (`switchTo` + reveal the panel).
    private(set) var chatController: ChatSessionController?

    /// Crash-recovery sidecars discovered on open that hold unsaved work the
    /// user should be prompted to recover or discard. Drives the recovery sheet
    /// in `VaultWindow`. Empty when the vault opened cleanly. Classification is
    /// the pure, unit-tested `RecoveryScan`.
    var pendingRecoveries: [RecoveryCandidate] = []

    private var watchTask: Task<Void, Never>?

    func openVault(at url: URL) async {
        isLoading = true

        // Progress flows from the repository/index actors (off the main actor)
        // through a stream that coalesces to the newest value, so thousands of
        // per-note ticks become a bounded number of @MainActor UI updates.
        let (progressStream, progress) = AsyncStream<VaultOpenProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let progressTask = Task { @MainActor [weak self] in
            for await update in progressStream {
                self?.openProgress = update
            }
        }
        defer {
            progress.finish()
            progressTask.cancel()
            openProgress = nil
            isLoading = false
        }

        let name = url.lastPathComponent
        let vault = Vault(name: name, rootURL: url)
        let previousVaultRoot = currentVault?.rootURL
        self.currentVault = vault

        // The shared chat controller is created eagerly with the vault so both the
        // sidebar and the chat panel can reach the same thread state. Its store is
        // still wired lazily (on first `loadInitialThread()`/persist), so this is
        // cheap. On a SAME-vault reopen, keep the existing controller: replacing
        // it would discard wired store + active thread while the views' `.task`s
        // (keyed on vault root) never re-fire to wire the replacement (PUNK-hdd).
        if chatController == nil || previousVaultRoot != url {
            self.chatController = ChatSessionController(appState: self)
        }

        do {
            let repo = FileSystemDocumentRepository(
                vaultRoot: url,
                ignoredPaths: vault.settings.ignoredPaths
            )
            self.repository = repo

            let index = try SQLiteSearchIndex(vaultRoot: url)
            self.searchIndex = index

            let recovery = FileSystemCrashRecoveryStore(vaultRoot: url)
            self.recoveryStore = recovery

            // Note compilation rides the session path (the same
            // FoundationModels/AnyLanguageModel machinery as chat) and follows
            // the SAME provider selection as the chat panel, resolved lazily
            // at each save/compile — so provider switches, new API keys, and
            // endpoint changes apply without reopening the vault, and a
            // missing key surfaces from the action instead of a dead fallback.
            let fallbackProvider = vault.settings.defaultLLMProvider
            self.noteCompiler = NoteCompiler(
                completer: DeferredSessionTextCompleter(
                    provider: { @Sendable in
                        ProviderRegistry.chatProvider(
                            from: UserDefaults.standard.string(forKey: ProviderRegistry.DefaultsKey.chatProvider),
                            default: fallbackProvider
                        )
                    },
                    keychain: keychainService
                ),
                repository: repo
            )

            // Heal any duplicate frontmatter IDs before indexing — duplicates
            // would otherwise confuse repo.document(withID:) and the backlink map.
            let healed = try await repo.healDuplicateIDs()
            if !healed.isEmpty {
                let summary = healed.map { "\($0.path): \($0.oldID) → \($0.newID)" }
                    .joined(separator: "; ")
                errorMessage = "Healed \(healed.count) duplicate document ID(s) on open."
                print("[VaultOpen] healed duplicate IDs: \(summary)")
            }

            let docs = try await repo.allDocuments(onProgress: { count in
                progress.yield(VaultOpenProgress(phase: .reading(notesRead: count)))
            })
            self.documents = docs
            try await index.rebuildIndex(documents: docs, onProgress: { completed, total in
                progress.yield(VaultOpenProgress(phase: .indexing(completed: completed, total: total)))
            })

            await repo.startWatching()
            startWatchingChanges(repo: repo)

            // Surface any unsaved edits stranded by a crash/power loss since the
            // last debounced save. Stale sidecars (note already up to date) are
            // discarded silently; genuine ones populate the recovery sheet.
            await scanForRecoverableNotes(store: recovery, docs: docs)
        } catch {
            errorMessage = "Failed to open vault: \(error.localizedDescription)"
        }
    }

    /// Sets up dependencies for preview use without async vault opening.
    func configureForPreview(vaultRoot: URL) {
        let repo = FileSystemDocumentRepository(vaultRoot: vaultRoot, ignoredPaths: [])
        self.repository = repo
        self.searchIndex = try? SQLiteSearchIndex(vaultRoot: vaultRoot)
    }

    func createNewNote() {
        guard currentVault != nil, let repo = repository else { return }
        let id = DocumentID()
        let parser = MarkdownParser()
        let frontmatter = parser.generateFrontmatter(id: id)
        let content = frontmatter + "\n\n# Untitled\n\n"

        Task {
            let path = await FilenameHelpers.uniqueNotePath(baseName: "Untitled") { candidate in
                (try? await repo.document(atPath: candidate)) != nil
            }
            let doc = Document(
                id: id,
                title: "Untitled",
                content: content,
                path: path
            )
            do {
                try await repo.save(doc)
            } catch {
                errorMessage = "Failed to create note: \(error.localizedDescription)"
                return
            }
            session.upsert(doc)
            if let index = searchIndex {
                try? await index.index(document: doc)
            }
            session.selectedPath = path
        }
    }

    /// Create a note with a specific title (used by click-to-create on an
    /// unresolved wikilink). The note's H1 and frontmatter title match `title`
    /// so future `[[title]]` links resolve to it.
    func createNote(titled title: String) {
        guard currentVault != nil, let repo = repository else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = DocumentID()
        let parser = MarkdownParser()
        let frontmatter = parser.generateFrontmatter(id: id)
        let content = frontmatter + "\n\n# \(trimmed)\n\n"
        let baseName = FilenameHelpers.sanitizeFilename(trimmed)

        Task {
            let path = await FilenameHelpers.uniqueNotePath(baseName: baseName) { candidate in
                (try? await repo.document(atPath: candidate)) != nil
            }
            let doc = Document(id: id, title: trimmed, content: content, path: path)
            do {
                try await repo.save(doc)
            } catch {
                errorMessage = "Failed to create note: \(error.localizedDescription)"
                return
            }
            session.upsert(doc)
            if let index = searchIndex {
                try? await index.index(document: doc)
            }
            session.selectedPath = path
        }
    }

    func renameDocument(_ doc: Document, to newTitle: String) async {
        guard let repo = repository else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let titleMatches = trimmed == doc.title
        let filenameMatches = trimmed == pathTitle(for: doc)
        guard !titleMatches || !filenameMatches else { return }

        let folder = (doc.path as NSString).deletingLastPathComponent
        let sanitized = FilenameHelpers.sanitizeFilename(trimmed)
        let newPath = folder.isEmpty ? "\(sanitized).md" : "\(folder)/\(sanitized).md"
        let isSamePath = newPath == doc.path

        if !isSamePath, (try? await repo.document(atPath: newPath)) != nil {
            errorMessage = "A note named “\(sanitized)” already exists."
            return
        }

        let updatedContent = FilenameHelpers.replaceFirstH1(in: doc.content, with: trimmed)
        let updatedDoc = Document(
            id: doc.id,
            title: trimmed,
            content: updatedContent,
            path: newPath,
            tags: doc.tags,
            created: doc.created,
            modified: Date(),
            frontmatter: doc.frontmatter,
            linkedDocumentIDs: doc.linkedDocumentIDs
        )

        do {
            try await repo.save(updatedDoc)
            if !isSamePath {
                try await repo.delete(doc)
            }
        } catch {
            errorMessage = "Failed to rename: \(error.localizedDescription)"
            return
        }

        session.applyRename(from: doc.path, to: updatedDoc)

        if let index = searchIndex {
            try? await index.index(document: updatedDoc)
        }
    }

    func deleteDocument(_ doc: Document) async {
        guard let repo = repository else { return }
        do {
            try await repo.delete(doc)
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
            return
        }
        session.remove(path: doc.path)
        if let index = searchIndex {
            try? await index.removeFromIndex(documentID: doc.id)
        }
    }

    // MARK: - Chat threads (sidebar)

    /// Ensure the shared chat controller's store is wired and its summaries
    /// loaded, so the sidebar Chats section populates even before the chat panel
    /// is ever opened. Idempotent (the controller guards re-entry / re-wiring).
    func loadChatThreadsIfNeeded() async {
        await chatController?.loadInitialThread()
    }

    /// Open a saved thread from the sidebar: activate it on the shared controller
    /// and reveal the chat panel.
    func openChatThread(id: UUID) async {
        await chatController?.switchTo(threadID: id)
        isChatPanelVisible = true
    }

    /// Start a new empty chat from the sidebar's Chats header (+) and reveal the
    /// panel. The controller persists the outgoing conversation before clearing.
    func startNewChatThread() {
        Task { await chatController?.newChat() }
        isChatPanelVisible = true
    }

    /// Delete a saved thread from the sidebar's row context menu.
    func deleteChatThread(id: UUID) async {
        await chatController?.deleteThread(id: id)
    }

    // MARK: - Crash Recovery

    /// Classify the recovery sidecars on disk against the just-loaded notes,
    /// discard the stale ones, and stage the recoverable ones for the sheet.
    /// The comparison itself is the pure `RecoveryScan`; this method is the thin
    /// glue that gathers note state and applies the result.
    private func scanForRecoverableNotes(
        store: FileSystemCrashRecoveryStore,
        docs: [Document]
    ) async {
        let sidecars = (try? await store.loadSidecars()) ?? []
        guard !sidecars.isEmpty else { return }

        var notes: [DocumentID: RecoveryNoteState] = [:]
        for doc in docs {
            notes[doc.id] = RecoveryNoteState(content: doc.content, modified: doc.modified)
        }

        let result = RecoveryScan.scan(sidecars: sidecars, notes: notes)

        // Silently drop sidecars whose note is already up to date.
        for noteID in result.stale {
            try? await store.removeSidecar(noteID: noteID)
        }

        pendingRecoveries = result.recoverable
    }

    /// Restore a recovery candidate's unsaved content into its note, persisting
    /// it durably and refreshing the in-memory session (and the open editor if
    /// it's showing that note). Drops the sidecar and clears the prompt.
    func recoverNote(_ candidate: RecoveryCandidate) async {
        guard let repo = repository else { return }

        // Resolve the note by its stable id; fall back to reconstructing one if
        // the note was lost entirely (sidecar with no surviving note).
        let existing = try? await repo.document(withID: candidate.noteID)
        let target: Document
        if let existing {
            target = Document(
                id: existing.id,
                title: existing.title,
                content: candidate.recoveredContent,
                path: existing.path,
                tags: existing.tags,
                created: existing.created,
                modified: Date(),
                frontmatter: existing.frontmatter,
                linkedDocumentIDs: existing.linkedDocumentIDs
            )
        } else {
            // Note gone: recover into a fresh file keyed by the recovered title.
            let parser = MarkdownParser()
            let parsed = parser.parse(content: candidate.recoveredContent, filename: "Recovered.md")
            let baseName = FilenameHelpers.sanitizeFilename(parsed.title.isEmpty ? "Recovered Note" : parsed.title)
            let path = await FilenameHelpers.uniqueNotePath(baseName: baseName) { candidatePath in
                (try? await repo.document(atPath: candidatePath)) != nil
            }
            target = Document(
                id: candidate.noteID,
                title: parsed.title,
                content: candidate.recoveredContent,
                path: path
            )
        }

        do {
            try await repo.save(target)
        } catch {
            errorMessage = "Failed to recover note: \(error.localizedDescription)"
            return
        }
        session.upsert(target)
        if let index = searchIndex {
            try? await index.index(document: target)
        }
        try? await recoveryStore?.removeSidecar(noteID: candidate.noteID)

        // If the recovered note is the one on screen, reload the editor so it
        // reflects the restored content instead of a stale copy.
        if selectedDocument?.id == candidate.noteID {
            editorReloadToken = UUID()
        }

        pendingRecoveries.removeAll { $0.noteID == candidate.noteID }
    }

    /// Discard a recovery candidate: delete its sidecar and drop the prompt.
    /// The note on disk is left untouched.
    func discardRecovery(_ candidate: RecoveryCandidate) async {
        try? await recoveryStore?.removeSidecar(noteID: candidate.noteID)
        pendingRecoveries.removeAll { $0.noteID == candidate.noteID }
    }

    // MARK: - Change Watching

    private func startWatchingChanges(repo: FileSystemDocumentRepository) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            let stream = await repo.changes
            for await change in stream {
                guard !Task.isCancelled, let self else { return }
                self.applyChange(change)
            }
        }
    }

    private func applyChange(_ change: VaultChange) {
        session.apply(change)
        // Tick to wake reactive consumers (e.g. BacklinksPanel) whose data
        // depends on cross-document state the session doesn't track.
        vaultChangeTick &+= 1
    }

    /// Increments on every observed VaultChange. Views that need to refresh
    /// when *any* document mutates (e.g. the backlinks panel, since changes
    /// to OTHER documents alter the current one's backlinks) can key their
    /// `.task(id:)` modifier off this counter alongside their primary key.
    var vaultChangeTick: Int = 0

    // MARK: - Helpers

    private func pathTitle(for doc: Document) -> String {
        ((doc.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
