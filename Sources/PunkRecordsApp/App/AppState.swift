import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Root application state. Owns the dependency container and top-level UI state.
@MainActor
@Observable
final class AppState {
    var currentVault: Vault?
    var selectedDocumentID: DocumentID?
    var isSearchPresented = false
    var isChatPanelVisible = false
    var isLoading = false
    var errorMessage: String?
    var askAIText: String?

    // Dependencies — initialized lazily when a vault is opened
    private(set) var repository: FileSystemDocumentRepository?
    private(set) var searchIndex: SQLiteSearchIndex?
    private(set) var orchestrator: LLMOrchestrator?
    private(set) var noteCompiler: NoteCompiler?
    private(set) var keychainService = KeychainService()

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

            // Build initial index
            let docs = try await repo.allDocuments()
            try await index.rebuildIndex(documents: docs)

            // Start watching for changes
            await repo.startWatching()
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
        guard let vault = currentVault else { return }
        let id = DocumentID()
        let parser = MarkdownParser()
        let frontmatter = parser.generateFrontmatter(id: id)
        let content = frontmatter + "\n\n# Untitled\n\n"

        let doc = Document(
            id: id,
            title: "Untitled",
            content: content,
            path: "Untitled.md"
        )

        Task {
            try? await repository?.save(doc)
            if let index = searchIndex {
                try? await index.index(document: doc)
            }
            selectedDocumentID = id
        }
    }
}
