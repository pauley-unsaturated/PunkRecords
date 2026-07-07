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
    ///
    /// `unowned`: since PUNK-9ss `AppState` OWNS this controller (single source of
    /// truth shared by the chat panel and the sidebar Chats section), so a strong
    /// back-reference would form a retain cycle. The controller never outlives its
    /// owning `AppState` (both die with the vault window), so `unowned` is safe.
    unowned let appState: AppState

    // MARK: - Transcript & streaming

    var isStreaming = false

    /// Token accounting captured from the most recent turn's final `.turnEnd`.
    /// Not rendered today; exposed for observability and to keep the reducer's
    /// usage capture reachable/testable.
    private(set) var lastTurnUsage: TokenUsage?

    // MARK: - Threads

    /// The thread-lifecycle orchestration — store wiring, persist/new/switch/
    /// delete/fork ORDERING, and summaries refresh — lifted into Core so the
    /// data-loss-adjacent ordering rules (PUNK-hdd, PUNK-b51) get `swift test`
    /// regression coverage with a mock ``ThreadStore``. The controller is now the
    /// UI glue: it forwards ``messages`` / ``activeThread`` / ``threadSummaries``
    /// and the lifecycle methods to this coordinator. Constructed in `init` with
    /// App/Infra dependencies injected as closures.
    let coordinator: ChatThreadCoordinator

    /// The live transcript, forwarded to the coordinator. Kept as the controller's
    /// surface so the view, the send pipeline, and the summarize flow read/write
    /// `messages` unchanged; SwiftUI observes the coordinator's stored state
    /// through this forward.
    var messages: [ChatMessage] {
        get { coordinator.messages }
        set { coordinator.messages = newValue }
    }

    /// The conversation currently shown (forwarded). `messages` mirrors its
    /// contents; the thread is persisted after each turn.
    var activeThread: ChatThread? { coordinator.activeThread }

    /// Lightweight rows for the thread switcher, sorted newest-first (forwarded).
    var threadSummaries: [ThreadSummary] { coordinator.threadSummaries }

    /// On-device embedder for `read_thread` query vectors and per-thread indexing.
    /// Loads its NaturalLanguage model lazily on first use. Shared between the
    /// coordinator's store factory (per-thread indexing) and ``runTurn`` (query
    /// vectors for `read_thread`).
    private let threadEmbedder: any ThreadEmbedder

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

        // One embedder, shared by the coordinator's store factory (per-thread
        // indexing on save) and `runTurn` (query vectors for `read_thread`).
        let embedder = NLThreadEmbedder()
        self.threadEmbedder = embedder

        // The coordinator's App/Infra dependencies are injected as closures. They
        // capture `appState` `unowned` (NOT strongly): `AppState` owns the
        // controller, which owns the coordinator, which owns these closures — a
        // strong back-reference would retain-cycle. The coordinator never outlives
        // its owning `AppState` (both die with the vault window), so `unowned` is
        // safe, matching the controller's own ``appState`` reference.
        self.coordinator = ChatThreadCoordinator(
            storeFactory: { [unowned appState] in
                guard let vaultRoot = appState.currentVault?.rootURL else { return nil }
                // Migrate on the concrete file store (migration is file-store-
                // specific), then wrap it in the embedding-indexing decorator used
                // from here on.
                let fileStore = FileSystemThreadStore(vaultRoot: vaultRoot)
                do {
                    try await fileStore.migrateLegacyTranscriptIfNeeded()
                } catch {
                    appState.errorMessage = "Failed to migrate chat history: \(error.localizedDescription)"
                }
                let indexed = EmbeddingIndexingThreadStore(
                    inner: fileStore,
                    embedder: embedder,
                    vaultRoot: vaultRoot
                )
                return WiredThreadStore(store: indexed, vectorSource: indexed)
            },
            focusNote: { [unowned appState] messages in
                // The note the conversation is about — the most recent message with
                // a resolvable note context — resolved against the current vault.
                ChatNoteContext.focusNote(for: messages) { id in
                    appState.documents.first { $0.id == id }
                }
                .map { ThreadFocusNote(title: $0.title, path: $0.path) }
            },
            reportError: { [unowned appState] message in
                appState.errorMessage = message
            }
        )
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
            if let threadStore = coordinator.threadStore {
                tools.append(ReadThreadTool(
                    store: threadStore,
                    embedder: threadEmbedder,
                    vectors: coordinator.threadVectorSource,
                    activeThreadID: coordinator.activeThread?.id
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

    // MARK: - Thread lifecycle (delegates to ChatThreadCoordinator)

    /// First-open setup for the panel: wire the store, migrate any legacy
    /// transcript into a thread, load the switcher list, and activate the most
    /// recent thread (or start a fresh empty one). Idempotent — safe to call from
    /// `.task`, which may re-run on reappearance. See ``ChatThreadCoordinator``.
    func loadInitialThread() async {
        await coordinator.loadInitialThread()
    }

    /// Start a new, empty conversation, persisting the current one FIRST and
    /// refusing to clear if that save did not land (PUNK-hdd, PUNK-b51). Also
    /// serves as the "clear" affordance.
    func newChat() async {
        await coordinator.newChat()
    }

    /// Switch to a stored thread, persisting the outgoing conversation first and
    /// refusing to switch when that save fails (same rule as ``newChat()``).
    func switchTo(threadID: UUID) async {
        await coordinator.switchTo(threadID: threadID)
    }

    /// Delete a thread, falling back to the next most recent (or a fresh one) when
    /// the active thread is the one deleted.
    func deleteThread(id: UUID) async {
        await coordinator.deleteThread(id: id)
    }

    /// Fork the active conversation at `messageID` over the live ``messages``.
    func forkThread(at messageID: UUID) async {
        await coordinator.forkThread(at: messageID)
    }

    /// Persist the active thread's current messages. Returns `false` when there
    /// were messages to save and the save did not land — callers about to clear
    /// the transcript must treat that as "do not discard" (PUNK-b51).
    @discardableResult
    func persistActiveThread() async -> Bool {
        await coordinator.persistActiveThread()
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
