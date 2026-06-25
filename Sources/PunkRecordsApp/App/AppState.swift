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
    private(set) var orchestrator: LLMOrchestrator?
    private(set) var noteCompiler: NoteCompiler?
    private(set) var keychainService = KeychainService()

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
        self.currentVault = vault

        do {
            let repo = FileSystemDocumentRepository(
                vaultRoot: url,
                ignoredPaths: vault.settings.ignoredPaths
            )
            self.repository = repo

            let index = try SQLiteSearchIndex(vaultRoot: url)
            self.searchIndex = index

            let contextBuilder = ContextBuilder(searchService: index, repository: repo)
            let orch = LLMOrchestrator(
                contextBuilder: contextBuilder,
                defaultProviderID: vault.settings.defaultLLMProvider,
                vaultName: name
            )

            // Register providers
            let anthropic = AnthropicProvider(keychainService: keychainService)
            await orch.registerProvider(anthropic)

            let openAI = OpenAIProvider(keychainService: keychainService)
            await orch.registerProvider(openAI)

            let foundation = FoundationModelsProvider()
            await orch.registerProvider(foundation)

            // Local models via Ollama (through Hugging Face's AnyLanguageModel).
            // Reports available only when an Ollama server is reachable.
            let anyLanguageModel = AnyLanguageModelProvider()
            await orch.registerProvider(anyLanguageModel)

            self.orchestrator = orch
            self.noteCompiler = NoteCompiler(orchestrator: orch, repository: repo)

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
