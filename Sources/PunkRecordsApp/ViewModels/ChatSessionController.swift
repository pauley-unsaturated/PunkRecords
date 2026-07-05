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
    /// the same surface `LLMChatPanel` used to reach for directly.
    private let appState: AppState

    // MARK: - Transcript & streaming

    var messages: [ChatMessage] = []
    var isStreaming = false

    /// Token accounting captured from the most recent turn's final `.turnEnd`.
    /// Not rendered today; exposed for observability and to keep the reducer's
    /// usage capture reachable/testable.
    private(set) var lastTurnUsage: TokenUsage?

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

    init(appState: AppState) {
        self.appState = appState
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
        persistTranscript()
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
        persistTranscript()
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
            persistTranscript()
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
            let tools: [any AgentTool] = [
                VaultSearchTool(searchService: searchIndex),
                ReadDocumentTool(repository: repository),
                CreateNoteTool(repository: repository),
                ListDocumentsTool(repository: repository),
            ]

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
            persistTranscript()
        }
    }

    // MARK: - Transcript persistence

    func loadTranscript() {
        guard messages.isEmpty, let vaultRoot = appState.currentVault?.rootURL else { return }
        do {
            messages = try ChatTranscriptStore.load(vaultRoot: vaultRoot)
        } catch {
            appState.errorMessage = "Failed to load chat transcript: \(error.localizedDescription)"
        }
    }

    func persistTranscript() {
        guard let vaultRoot = appState.currentVault?.rootURL else { return }
        do {
            try ChatTranscriptStore.save(messages: messages, vaultRoot: vaultRoot)
        } catch {
            appState.errorMessage = "Failed to save chat transcript: \(error.localizedDescription)"
        }
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
