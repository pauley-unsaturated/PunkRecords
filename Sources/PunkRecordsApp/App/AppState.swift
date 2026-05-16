import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Root application state. Owns the dependency container and top-level UI state.
@MainActor
@Observable
final class AppState {
    var currentVault: Vault?
    /// Stable selection key. Path is unique on disk; document ids may collide
    /// when vaults have duplicate frontmatter.
    var selectedDocumentPath: RelativePath?
    var isSearchPresented = false
    var isChatPanelVisible = false
    var isBacklinksPanelVisible = true
    var isLoading = false
    var errorMessage: String?
    var askAIText: String?
    var selectedText: String?

    /// Authoritative document list for the open vault. Mirrors the disk via the FS watcher.
    var documents: [Document] = []

    /// The currently selected document, resolved from `selectedDocumentPath`.
    var selectedDocument: Document? {
        guard let path = selectedDocumentPath else { return nil }
        return documents.first { $0.path == path }
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
            let path = await Self.uniqueNotePath(in: repo, baseName: "Untitled")
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
            upsert(doc)
            if let index = searchIndex {
                try? await index.index(document: doc)
            }
            selectedDocumentPath = path
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
        let sanitized = Self.sanitizeFilename(trimmed)
        let newPath = folder.isEmpty ? "\(sanitized).md" : "\(folder)/\(sanitized).md"
        let isSamePath = newPath == doc.path

        if !isSamePath, (try? await repo.document(atPath: newPath)) != nil {
            errorMessage = "A note named “\(sanitized)” already exists."
            return
        }

        let updatedContent = Self.replaceFirstH1(in: doc.content, with: trimmed)
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

        if !isSamePath {
            documents.removeAll { $0.path == doc.path }
            if selectedDocumentPath == doc.path {
                selectedDocumentPath = newPath
            }
        }
        upsert(updatedDoc)

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
        documents.removeAll { $0.path == doc.path }
        if selectedDocumentPath == doc.path {
            selectedDocumentPath = nil
        }
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
        switch change {
        case .added(let doc), .modified(let doc):
            upsert(doc)
        case .deleted(_, let path):
            documents.removeAll { $0.path == path }
        }
    }

    /// Upsert by **path first** (path is unique on disk) then by id (which can collide
    /// in vaults with duplicate frontmatter ids).
    private func upsert(_ doc: Document) {
        if let idx = documents.firstIndex(where: { $0.path == doc.path }) {
            documents[idx] = doc
        } else if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
    }

    // MARK: - Helpers

    private func pathTitle(for doc: Document) -> String {
        ((doc.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func uniqueNotePath(in repo: FileSystemDocumentRepository, baseName: String) async -> String {
        var candidate = "\(baseName).md"
        var n = 2
        while (try? await repo.document(atPath: candidate)) != nil {
            candidate = "\(baseName) \(n).md"
            n += 1
        }
        return candidate
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    /// Replace the first H1 in the body (post-frontmatter). If no H1 exists, insert one.
    static func replaceFirstH1(in content: String, with newTitle: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var bodyStart = 0

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = i + 1
                break
            }
        }

        var result = Array(lines[0..<bodyStart])
        var replaced = false
        for i in bodyStart..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if !replaced && trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
                result.append("# \(newTitle)")
                replaced = true
            } else {
                result.append(lines[i])
            }
        }

        if !replaced {
            var insertAt = bodyStart
            while insertAt < result.count && result[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            result.insert("# \(newTitle)", at: insertAt)
            if insertAt + 1 >= result.count || !result[insertAt + 1].isEmpty {
                result.insert("", at: insertAt + 1)
            }
        }

        return result.joined(separator: "\n")
    }
}
