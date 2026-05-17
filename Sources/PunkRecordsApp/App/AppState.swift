import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Root application state. Owns the dependency container and top-level UI state.
@MainActor
@Observable
final class AppState {
    var currentVault: Vault?
    var isSearchPresented = false
    var isChatPanelVisible = false
    var isBacklinksPanelVisible = true
    var isLoading = false
    var errorMessage: String?
    var askAIText: String?
    var selectedText: String?

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

    // Dependencies — initialized lazily when a vault is opened
    private(set) var repository: FileSystemDocumentRepository?
    private(set) var searchIndex: SQLiteSearchIndex?
    private(set) var orchestrator: LLMOrchestrator?
    private(set) var noteCompiler: NoteCompiler?
    private(set) var keychainService = KeychainService()

    private var watchTask: Task<Void, Never>?

    func openVault(at url: URL) async {
        isLoading = true
        defer { isLoading = false }

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

            let docs = try await repo.allDocuments()
            self.documents = docs
            try await index.rebuildIndex(documents: docs)

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
    }

    // MARK: - Helpers

    private func pathTitle(for doc: Document) -> String {
        ((doc.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
