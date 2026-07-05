import Foundation
import PunkRecordsCore
import PunkRecordsInfra

/// The volatile, per-turn inputs the chat panel resolves from settings + app
/// state and hands to the controller. Kept as an explicit value (rather than
/// read from the controller) so `@AppStorage` provider/scope selection stays in
/// the view and the send pipeline reads a stable snapshot.
struct ChatTurnParameters {
    let provider: LLMProviderID
    let config: LanguageModelFactory.Config
    let scope: QueryScope
    let scopeLabel: String
    let selectedText: String?
    let currentDocumentID: DocumentID?
    let vaultName: String
}

/// Owns chat orchestration lifted out of `LLMChatPanel`: transcript + streaming
/// state, attachment/composer state, provider availability, the send pipeline
/// (attachment→prompt building, provider/model resolution, tool construction,
/// `SessionAgentRunner` event streaming via ``ChatTurnReducer``), transcript
/// persistence, and the save-as-note / report-issue actions.
///
/// The view stays a thin shell: it renders `messages`, binds composer state,
/// owns provider/scope pickers and keyboard focus, and calls into the controller.
@MainActor
@Observable
final class ChatSessionController {
    /// Dependency container. The controller reaches through it for the
    /// repository, search index, keychain, note compiler, vault, and selection —
    /// the same surface `LLMChatPanel` used to reach for directly. Internal (not
    /// `private`) so same-controller extensions in sibling files (e.g. the
    /// summarize-to-note flow) can reach the same dependencies.
    let appState: AppState

    // MARK: - Transcript & streaming

    var messages: [ChatMessage] = []
    var isStreaming = false

    /// Token accounting captured from the most recent turn's final `.turnEnd`.
    /// Not rendered today; exposed for observability and to keep the reducer's
    /// usage capture reachable/testable.
    private(set) var lastTurnUsage: TokenUsage?

    // MARK: - Threads

    /// The conversation currently shown. `messages` mirrors its contents; the
    /// thread is persisted after each turn. `nil` only before the first
    /// ``loadInitialThread()``.
    private(set) var activeThread: ChatThread?

    /// Lightweight rows for the thread switcher, sorted newest-first. Refreshed
    /// after every save/delete.
    private(set) var threadSummaries: [ThreadSummary] = []

    /// Resolved lazily from the open vault by ``loadInitialThread()``. This is the
    /// embedding-indexing decorator wrapping the file store, so every persisted
    /// thread gets an on-device embedding for `read_thread`'s semantic mode.
    private var threadStore: (any ThreadStore)?

    /// The same object as ``threadStore``, surfaced as its ``ThreadVectorSource``
    /// so `read_thread` can read cached per-thread vectors. `nil` until wired.
    private var threadVectorSource: (any ThreadVectorSource)?

    /// On-device embedder for `read_thread` query vectors and per-thread indexing.
    /// Loads its NaturalLanguage model lazily on first use.
    private let threadEmbedder: any ThreadEmbedder = NLThreadEmbedder()

    // MARK: - Composer input

    var prompt = ""
    var pendingAttachments: [PendingChatAttachment] = []

    // MARK: - Attachment import / drop / alerts

    var isAttachmentImporterPresented = false
    var isAttachmentDropTargeted = false
    var isShowingAttachmentError = false
    var attachmentAlertTitle = "Attachment Error"
    var attachmentErrorMessage = ""
    var isShowingImageProviderAlert = false
    var isShowingSendConfirmation = false
    private(set) var deferredSendText = ""
    private(set) var deferredSendAttachments: [PendingChatAttachment] = []

    // MARK: - Providers

    var availableProviders: [LLMProviderID] = []

    // MARK: - Summarize-to-note

    /// Set while the one-shot summarization completion is in flight — disables the
    /// "Summarize to Note" action and drives its spinner. The summary is NOT
    /// injected into the transcript; it lives here until saved/copied/discarded.
    /// Controller-owned (mutated only by the summarize flow in the extension).
    var isSummarizing = false

    /// The finished summary body, retained from the moment it's ready until the
    /// user saves, copies, or discards it. Non-nil ⇒ an unsaved summary exists.
    /// Controller-owned (mutated only by the summarize flow in the extension).
    var summaryBody: String?

    /// Editable save-sheet fields: title (prefilled `Summary — <thread title>`)
    /// and destination folder (defaults to the vault root).
    var summaryTitle = ""
    var summaryFolder: RelativePath = ""

    /// Drives the destination save sheet.
    var isShowingSummarySaveSheet = false
    /// Drives the post-cancel fallback alert (Copy to Clipboard / Retry Save /
    /// Discard) so a produced summary is never silently lost.
    var isShowingSummaryFallback = false

    /// The summarizer for the in-flight flow. Held across phases so the same
    /// repository-backed instance handles both `summarize` and `saveSummaryNote`
    /// (including a retry) without reconstructing an unused completer.
    var summarizer: ConversationSummarizer?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Existing vault folders offered by the save sheet's destination picker,
    /// vault root first. Reuses the sidebar's folder grouping so the list matches
    /// what the user sees in the browser.
    var summaryFolderOptions: [RelativePath] {
        SidebarFilter.filter(documents: appState.documents, query: "").map(\.folder)
    }

    /// Whether the active conversation has anything worth summarizing. Backs the
    /// menu item's disabled state. False while streaming or already summarizing.
    var canSummarize: Bool {
        !isStreaming
            && !isSummarizing
            && ConversationSummarizer.hasSummarizableContent(messages)
    }

    // MARK: - Derived composer state

    var canSendMessage: Bool {
        (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
            && !isStreaming
    }

    var formattedTokenEstimate: String {
        let estimate = ChatAttachmentPolicy.estimatedTokens(
            prompt: prompt,
            attachments: pendingAttachments.map(\.metadata)
        )
        return estimate.formatted(.number.notation(.compactName))
    }

    // MARK: - Providers

    func refreshAvailableProviders(config: LanguageModelFactory.Config) async {
        // Local providers can be probed here, but remote providers intentionally
        // do not read Keychain until a turn actually builds the model.
        availableProviders = await LanguageModelFactory.availableProviders(
            keychain: appState.keychainService,
            config: config
        )
    }

    // MARK: - Send pipeline

    /// Validate the composer and either send immediately or, for a large/heavy
    /// submission, stash it and raise the confirmation alert.
    func queueSend(_ turn: ChatTurnParameters) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if ChatAttachmentPolicy.needsConfirmation(
            prompt: text,
            attachments: pendingAttachments.map(\.metadata)
        ) {
            deferredSendText = text
            deferredSendAttachments = pendingAttachments
            isShowingSendConfirmation = true
            return
        }

        Task { await send(text: text, attachments: pendingAttachments, turn: turn) }
    }

    /// Send the submission the confirmation alert deferred, re-reading the
    /// current turn parameters (matching the pre-refactor behavior).
    func confirmDeferredSend(_ turn: ChatTurnParameters) {
        Task { await send(text: deferredSendText, attachments: deferredSendAttachments, turn: turn) }
    }

    private func send(text: String, attachments: [PendingChatAttachment], turn: ChatTurnParameters) async {
        guard !text.isEmpty || !attachments.isEmpty else { return }

        if attachments.contains(where: { $0.metadata.type == .image }),
           !turn.provider.nativeImageInput {
            isShowingImageProviderAlert = true
            return
        }

        let agentPrompt: String
        let imageAttachments: [SessionImageAttachment]
        do {
            let textPrompt = try TextChatAttachmentHandler.prompt(
                userText: text,
                attachments: attachments.map {
                    TextChatAttachmentInput(url: $0.url, metadata: $0.metadata)
                }
            )
            agentPrompt = try PDFChatAttachmentHandler.prompt(
                userText: textPrompt,
                attachments: attachments.map {
                    PDFChatAttachmentInput(url: $0.url, metadata: $0.metadata)
                }
            )
            imageAttachments = try attachments
                .filter { $0.metadata.type == .image }
                .map { attachment in
                    let payload = try ImageChatAttachmentHandler.payload(
                        for: ImageChatAttachmentInput(url: attachment.url, metadata: attachment.metadata),
                        provider: turn.provider
                    )
                    return SessionImageAttachment(data: payload.data, mimeType: payload.mimeType)
                }
        } catch {
            showAttachmentError(error.localizedDescription)
            return
        }

        let attachmentMetadata = attachments.map(\.metadata)
        let attachmentTranscript = (try? ChatAttachmentPolicy.transcriptComments(for: attachmentMetadata)) ?? ""
        let userMessage = ChatMessage(
            role: .user,
            content: text,
            attachments: attachmentMetadata,
            attachmentTranscript: attachmentTranscript
        )
        messages.append(userMessage)
        await persistActiveThread()
        prompt = ""
        pendingAttachments = []

        // Snapshot the submission context. Attached to the assistant message so
        // "Report Issue" can later reconstruct the full state that produced the response.
        let context = MessageContext(
            scope: turn.scope,
            scopeLabel: turn.scopeLabel,
            currentDocumentID: turn.currentDocumentID,
            selection: turn.selectedText,
            variantID: "terse-v1",
            userPrompt: text
        )

        isStreaming = true
        await runTurn(agentPrompt, images: imageAttachments, context: context, turn: turn)
        await persistActiveThread()
        isStreaming = false
    }

    /// Produce an `AgentEvent` stream via the FoundationModels session path
    /// (`SessionAgentRunner` + `LanguageModelFactory` + `buildInstructions`) and
    /// fold it into the transcript. The session owns the agentic tool loop; this
    /// only translates events into chat rows via ``ChatTurnReducer``.
    private func runTurn(
        _ text: String,
        images: [SessionImageAttachment],
        context: MessageContext,
        turn: ChatTurnParameters
    ) async {
        guard let repository = appState.repository,
              let searchIndex = appState.searchIndex else {
            messages.append(ChatMessage(role: .assistant, content: "Vault not loaded.", context: context))
            await persistActiveThread()
            return
        }

        do {
            // Resolve the backing model for the selected provider.
            let model = try LanguageModelFactory.makeModel(
                for: turn.provider,
                keychain: appState.keychainService,
                config: turn.config
            )

            // Build instructions (system prompt + tiered vault excerpts) exactly
            // as the old AgentLoop path did, via the shared ContextBuilder.
            let contextBuilder = ContextBuilder(searchService: searchIndex, repository: repository)
            let instructions = try await contextBuilder.buildInstructions(
                prompt: text,
                scope: turn.scope,
                currentDocumentID: turn.currentDocumentID,
                maxTokens: ProviderRegistry.contextBudget(for: turn.provider),
                vaultName: turn.vaultName
            )

            // The session owns the tool loop; hand it the same Core AgentTools.
            // The web fetcher is a standalone Infra service the tool wraps, so a
            // future web-search feature (PUNK-e5u) can reuse it. Tier 2 uses a
            // WKWebView (built here on the main actor); Tier 3 (Jina) is gated on
            // per-domain consent surfaced via a thin App-side dialog.
            let consentStore = WebFetchConsentStore()
            let webFetcher = ThreeTierWebContentFetcher.makeDefault(
                vaultRoot: appState.currentVault?.rootURL,
                jinaConsent: WebFetchConsentPrompt.makeConsentClosure(store: consentStore)
            )
            var tools: [any AgentTool] = [
                VaultSearchTool(searchService: searchIndex),
                ReadDocumentTool(repository: repository),
                CreateNoteTool(repository: repository),
                ListDocumentsTool(repository: repository),
                WebFetchTool(fetcher: webFetcher),
            ]
            // Let the model reference the user's other saved conversations. The
            // active thread is excluded so it never cites the chat it's already in.
            if let threadStore {
                tools.append(ReadThreadTool(
                    store: threadStore,
                    embedder: threadEmbedder,
                    vectors: threadVectorSource,
                    activeThreadID: activeThread?.id
                ))
            }

            // Fold any selected text into the user prompt, matching AgentLoop.
            let userPrompt: String
            if let sel = turn.selectedText, !sel.isEmpty {
                userPrompt = "Selected text: \(sel)\n\n\(text)"
            } else {
                userPrompt = text
            }

            let runner = SessionAgentRunner(
                model: model,
                instructions: instructions,
                tools: tools
            )

            let stream = await runner.run(prompt: userPrompt, images: images)

            var reducerState = ChatTurnReducer.State()
            for try await event in stream {
                ChatTurnReducer.apply(
                    event,
                    to: &messages,
                    state: &reducerState,
                    context: context,
                    providerID: turn.provider
                )
            }
            lastTurnUsage = reducerState.lastUsage
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "*Error: \(error.localizedDescription)*", context: context))
            await persistActiveThread()
        }
    }

    // MARK: - Thread lifecycle

    /// First-open setup for the panel: wire the store, migrate any legacy
    /// transcript into a thread, load the switcher list, and activate the most
    /// recent thread (or start a fresh empty one). Idempotent — safe to call from
    /// `.task`, which may re-run on reappearance.
    func loadInitialThread() async {
        guard let vaultRoot = appState.currentVault?.rootURL else { return }

        if threadStore == nil {
            // Migrate on the concrete file store (migration is file-store-specific),
            // then wrap it in the embedding-indexing decorator used from here on.
            let fileStore = FileSystemThreadStore(vaultRoot: vaultRoot)
            do {
                try await fileStore.migrateLegacyTranscriptIfNeeded()
            } catch {
                appState.errorMessage = "Failed to migrate chat history: \(error.localizedDescription)"
            }
            let indexed = EmbeddingIndexingThreadStore(
                inner: fileStore,
                embedder: threadEmbedder,
                vaultRoot: vaultRoot
            )
            threadStore = indexed
            threadVectorSource = indexed
        }

        await refreshThreadSummaries()

        // Already showing a thread (e.g. .task re-ran) — don't clobber it.
        guard activeThread == nil else { return }

        if let store = threadStore,
           let newest = threadSummaries.first,
           let loaded = try? await store.load(id: newest.id) {
            activate(loaded)
        } else {
            startFreshThread()
        }
    }

    /// Start a new, empty conversation. The thread is held in memory and only
    /// written to disk once it has content (see ``persistActiveThread()``), so
    /// unused "New Chat" presses never clutter the switcher. Also serves as the
    /// "clear" affordance.
    func newChat() {
        startFreshThread()
    }

    /// Switch to a stored thread, loading its messages into the transcript. A
    /// no-op if the id can't be loaded. The previously-active thread is already
    /// persisted (every turn saves), so nothing is lost — except an untouched
    /// empty new thread, which is intentionally dropped.
    func switchTo(threadID: UUID) async {
        guard let store = threadStore else { return }
        guard let loaded = try? await store.load(id: threadID) else { return }
        activate(loaded)
    }

    /// Delete a thread. If it was the active one, fall back to the next most
    /// recent thread, or a fresh empty one when none remain.
    func deleteThread(id: UUID) async {
        guard let store = threadStore else { return }
        do {
            try await store.delete(id: id)
        } catch {
            appState.errorMessage = "Failed to delete chat: \(error.localizedDescription)"
            return
        }
        await refreshThreadSummaries()

        guard activeThread?.id == id else { return }
        if let newest = threadSummaries.first,
           let loaded = try? await store.load(id: newest.id) {
            activate(loaded)
        } else {
            startFreshThread()
        }
    }

    /// Fork the active conversation at `messageID`: create a new thread holding
    /// the transcript up to AND INCLUDING that message, with lineage back to the
    /// active thread, then persist it and switch to it. The original thread is
    /// left untouched (already on disk from its own turns). A no-op when there is
    /// no active thread/store or the id isn't in the current transcript.
    ///
    /// Forks over the live `messages` (not `activeThread.messages`) so an unsaved
    /// streaming tail is captured, and so the branch matches exactly what the user
    /// sees on screen.
    func forkThread(at messageID: UUID) async {
        guard let store = threadStore, let source = activeThread else { return }
        var forkSource = source
        forkSource.messages = messages
        guard let fork = ChatThreadHelpers.fork(forkSource, atMessageID: messageID) else { return }
        do {
            try await store.save(fork)
        } catch {
            appState.errorMessage = "Failed to fork chat: \(error.localizedDescription)"
            return
        }
        activate(fork)
        await refreshThreadSummaries()
    }

    /// Persist the active thread's current messages. Skips empty conversations so
    /// a brand-new thread only lands on disk once it has content. Re-derives the
    /// title and bumps `updatedAt`, then refreshes the switcher.
    func persistActiveThread() async {
        guard let store = threadStore, !messages.isEmpty else { return }
        var thread = activeThread ?? ChatThread()
        thread.update(messages: messages)
        activeThread = thread
        do {
            try await store.save(thread)
        } catch {
            appState.errorMessage = "Failed to save chat: \(error.localizedDescription)"
            return
        }
        await refreshThreadSummaries()
    }

    private func activate(_ thread: ChatThread) {
        activeThread = thread
        messages = thread.messages
    }

    private func startFreshThread() {
        activeThread = ChatThread()
        messages = []
    }

    private func refreshThreadSummaries() async {
        guard let store = threadStore else { return }
        let loaded = (try? await store.summaries()) ?? []
        threadSummaries = ChatThreadHelpers.sortedSummaries(loaded)
    }

    // MARK: - Attachments

    func openAttachmentImporter() {
        isAttachmentImporterPresented = true
    }

    func handleAttachmentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addAttachmentURLs(urls)
        case .failure(let error):
            showAttachmentError(error.localizedDescription)
        }
    }

    func addAttachmentURLs(_ urls: [URL]) {
        var warnings: [String] = []
        do {
            for url in urls where !pendingAttachments.contains(where: { $0.url == url }) {
                let attachment = try PendingChatAttachment.make(for: url)
                pendingAttachments.append(attachment)
                if let warning = attachment.warning {
                    warnings.append(warning)
                }
            }
            if !warnings.isEmpty {
                showAttachmentWarning(warnings.joined(separator: "\n"))
            }
        } catch {
            showAttachmentError(error.localizedDescription)
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    private func showAttachmentError(_ message: String) {
        attachmentAlertTitle = "Attachment Error"
        attachmentErrorMessage = message
        isShowingAttachmentError = true
    }

    private func showAttachmentWarning(_ message: String) {
        attachmentAlertTitle = "Attachment Warning"
        attachmentErrorMessage = message
        isShowingAttachmentError = true
    }

    // MARK: - Selected-note context

    /// The note a historical message was about, resolved for the per-message
    /// context chip. Reads the message's persisted ``MessageContext`` (scope +
    /// current document) and resolves its note against the *current* vault, so a
    /// reloaded thread still gets a chip as long as the note still exists. Returns
    /// `nil` for vault-wide turns or notes that can no longer be resolved.
    ///
    /// The scope/decision logic is the pure ``ChatNoteContext``; the controller
    /// only supplies the repository-style lookup (kept out of the view).
    func contextChip(for message: ChatMessage) -> ChatNoteContext.Reference? {
        guard let context = message.context,
              let noteID = ChatNoteContext.referencedNoteID(
                  scope: context.scope,
                  currentDocumentID: context.currentDocumentID
              ) else { return nil }
        return ChatNoteContext.reference(for: context, document: resolveDocument(id: noteID))
    }

    /// The note the NEXT turn will be about, for the composer banner, given the
    /// live scope. Resolves the scope's referenced note against the current vault;
    /// `nil` (banner hidden) when the scope is vault-wide or nothing resolves.
    func composerBanner(scope: QueryScope) -> ChatNoteContext.Reference? {
        let currentDocumentID = appState.selectedDocument?.id
        guard let noteID = ChatNoteContext.referencedNoteID(
            scope: scope,
            currentDocumentID: currentDocumentID
        ) else { return nil }
        return ChatNoteContext.reference(
            scope: scope,
            currentDocumentID: currentDocumentID,
            document: resolveDocument(id: noteID)
        )
    }

    /// Navigate the vault to `path`, reusing the same selection-driven navigation
    /// QuickOpen / search use (`selectedDocumentPath`). Backs the chip / banner tap.
    func openNote(path: RelativePath) {
        appState.selectedDocumentPath = path
    }

    /// Resolve a document id against the in-memory vault snapshot (which mirrors
    /// disk via the FS watcher). `nil` if it no longer exists.
    private func resolveDocument(id: DocumentID) -> Document? {
        appState.documents.first { $0.id == id }
    }

    // MARK: - Message actions

    func saveAsNote(_ content: String) async {
        guard let compiler = appState.noteCompiler else { return }
        do {
            let doc = try await compiler.saveResponseAsNote(
                responseText: content,
                sourceDocumentID: appState.selectedDocument?.id,
                folderPath: ""
            )
            appState.selectedDocumentPath = doc.path
        } catch {
            appState.errorMessage = "Failed to save note: \(error.localizedDescription)"
        }
    }

    func reportIssueCopy(_ message: ChatMessage) async {
        guard let report = await buildReport(for: message) else { return }
        IssueReporter.copyToClipboard(report)
        appState.errorMessage = "Issue report copied to clipboard."
    }

    func reportIssueSave(_ message: ChatMessage) async {
        guard let report = await buildReport(for: message) else { return }
        do {
            let url = try IssueReporter.save(report)
            appState.errorMessage = "Issue saved to \(url.path)"
        } catch {
            appState.errorMessage = "Failed to save issue: \(error.localizedDescription)"
        }
    }

    // MARK: - Issue reporting

    /// Build an IssueReport for the given assistant message and prior conversation.
    private func buildReport(for message: ChatMessage) async -> IssueReport? {
        guard let context = message.context else { return nil }
        // Include prior messages up to (but not including) the reported one.
        let reportedIndex = messages.firstIndex(where: { $0.id == message.id }) ?? messages.count
        let prior = messages.prefix(reportedIndex).map {
            (role: $0.role == .user ? "user" : "assistant", content: $0.content)
        }
        return await IssueReporter.build(
            assistantResponse: message.content,
            context: context,
            priorMessages: Array(prior),
            appState: appState
        )
    }
}
