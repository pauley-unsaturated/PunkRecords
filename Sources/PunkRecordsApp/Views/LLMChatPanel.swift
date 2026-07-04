import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

struct LLMChatPanel: View {
    @Environment(AppState.self) private var appState
    @State private var prompt = ""
    @State private var messages: [ChatMessage] = []
    @State private var isStreaming = false
    @State private var scope: QueryScope = .global
    @State private var availableProviders: [LLMProviderID] = []
    @State private var pendingAttachments: [PendingChatAttachment] = []
    @State private var isAttachmentImporterPresented = false
    @State private var isAttachmentDropTargeted = false
    @State private var isShowingAttachmentError = false
    @State private var isShowingImageProviderAlert = false
    @State private var attachmentAlertTitle = "Attachment Error"
    @State private var attachmentErrorMessage = ""
    @State private var isShowingSendConfirmation = false
    @State private var deferredSendText = ""
    @State private var deferredSendAttachments: [PendingChatAttachment] = []
    @AppStorage("chatProviderID") private var chatProviderRaw: String = LLMProviderID.anthropic.rawValue
    @AppStorage("ollama.model") private var ollamaModel = "qwen3"
    @AppStorage("ollama.baseURL") private var ollamaBaseURL = "http://localhost:11434"
    @AppStorage("openai.baseURL") private var openAIBaseURL = ""

    private var selectedProviderID: LLMProviderID {
        LLMProviderID(rawValue: chatProviderRaw) ?? .anthropic
    }

    /// Endpoint/model config sourced from Settings, used both to decide
    /// availability and to build the backing model for a turn.
    private var factoryConfig: LanguageModelFactory.Config {
        LanguageModelFactory.Config(
            ollamaModel: ollamaModel.isEmpty ? "qwen3" : ollamaModel,
            ollamaEndpoint: URL(string: ollamaBaseURL) ?? URL(string: "http://localhost:11434")!,
            openAIEndpoint: openAIBaseURL.isEmpty ? nil : URL(string: openAIBaseURL)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Chat")
                    .font(.headline)
                Spacer()
                providerPicker
                scopePicker
                Button("Close", systemImage: "xmark.circle.fill") {
                    appState.isChatPanelVisible = false
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(providerKeyboardShortcuts)
            .task {
                loadTranscript()

                // Re-probe while the panel is open so a provider that comes online
                // after launch (e.g. you start `ollama serve`, or add an API key in
                // Settings) un-grays on its own without reopening the panel.
                while !Task.isCancelled {
                    await refreshAvailableProviders()
                    try? await Task.sleep(for: .seconds(4))
                }
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            Group {
                                if message.role == .tool, let call = message.toolCall {
                                    ToolCallBubble(toolCall: call)
                                } else {
                                    ChatBubble(
                                        message: message,
                                        onSaveAsNote: { Task { await saveAsNote(message.content) } },
                                        onReportIssueCopy: { Task { await reportIssueCopy(message) } },
                                        onReportIssueSave: { Task { await reportIssueSave(message) } }
                                    )
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            chatComposer
        }
        .frame(minWidth: 300, idealWidth: 350)
        .onChange(of: appState.askAIText) { _, newValue in
            if let text = newValue {
                prompt = "Regarding this selection:\n\n> \(text)\n\n"
                appState.askAIText = nil
                scope = .selection
            }
        }
        .fileImporter(
            isPresented: $isAttachmentImporterPresented,
            allowedContentTypes: PendingChatAttachment.allowedContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleAttachmentImport
        )
        .alert(attachmentAlertTitle, isPresented: $isShowingAttachmentError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentErrorMessage)
        }
        .alert("Large chat submission", isPresented: $isShowingSendConfirmation) {
            Button("Send", role: .destructive) {
                Task {
                    await sendMessage(
                        text: deferredSendText,
                        attachments: deferredSendAttachments
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message is estimated at \(formattedTokenEstimate) tokens or includes a file larger than 20 MB.")
        }
        .alert("Image Provider Unsupported", isPresented: $isShowingImageProviderAlert) {
            Button("Use Claude") {
                chatProviderRaw = LLMProviderID.anthropic.rawValue
            }
            Button("Use GPT") {
                chatProviderRaw = LLMProviderID.openAI.rawValue
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple does not support image attachments. Switch to Claude or GPT to send images.")
        }
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            ChatAttachmentChip(metadata: attachment.metadata) {
                                removeAttachment(id: attachment.id)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("chatAttachmentChips")
            }

            Text("Estimated: ~\(formattedTokenEstimate) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Estimated tokens")
                .accessibilityValue(formattedTokenEstimate)
                .accessibilityIdentifier("chatTokenEstimate")

            HStack(alignment: .bottom, spacing: 8) {
                Button("Attach File", systemImage: "paperclip", action: openAttachmentImporter)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("A", modifiers: [.command, .shift])
                    .help("Attach files")
                    .accessibilityLabel("Attach File")
                    .accessibilityIdentifier("chatAttachButton")

                TextField("Ask about your vault...", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(queueSendMessage)

                Button("Send message", systemImage: "arrow.up.circle.fill", action: queueSendMessage)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .disabled(!canSendMessage)
                    .accessibilityIdentifier("chatSendButton")
            }
        }
        .padding()
        .overlay {
            if isAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Drop files to attach")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addAttachmentURLs(urls)
            return true
        } isTargeted: { isTargeted in
            isAttachmentDropTargeted = isTargeted
        }
    }

    private var providerPicker: some View {
        Menu {
            ForEach(LLMProviderID.allCases, id: \.self) { id in
                Button {
                    chatProviderRaw = id.rawValue
                } label: {
                    HStack {
                        if id == selectedProviderID {
                            Image(systemName: "checkmark")
                        }
                        Text(id.displayName)
                        if !availableProviders.contains(id) {
                            Text("(not configured)").foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!availableProviders.contains(id))
            }
        } label: {
            Label(selectedProviderID.displayName, systemImage: "cpu")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .help("Choose the LLM provider for this conversation. \u{2318}1/2/3/4 to switch.")
        .accessibilityIdentifier("chatProviderPicker")
    }

    /// Hidden buttons that own keyboard shortcuts for provider switching.
    /// Placed inside `.background` so they receive shortcuts while the chat
    /// panel is focused but don't take visual space.
    private var providerKeyboardShortcuts: some View {
        ZStack {
            providerShortcutButton(.foundationModels, key: "1")
            providerShortcutButton(.anthropic, key: "2")
            providerShortcutButton(.openAI, key: "3")
            providerShortcutButton(.anyLanguageModel, key: "4")
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    private func providerShortcutButton(_ id: LLMProviderID, key: KeyEquivalent) -> some View {
        Button(id.displayName) {
            if availableProviders.contains(id) {
                chatProviderRaw = id.rawValue
            }
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    private func refreshAvailableProviders() async {
        // Local providers can be probed here, but remote providers intentionally
        // do not read Keychain until a turn actually builds the model.
        availableProviders = await LanguageModelFactory.availableProviders(
            keychain: appState.keychainService,
            config: factoryConfig
        )
    }

    private var scopePicker: some View {
        Menu {
            Button("Entire KB") { scope = .global }
            if let docID = appState.selectedDocument?.id {
                Button("Current Document") { scope = .document(docID) }
            }
        } label: {
            Label(scopeLabel, systemImage: "scope")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
    }

    private var scopeLabel: String {
        switch scope {
        case .global: "KB-wide"
        case .document: "Document"
        case .folder: "Folder"
        case .selection: "Selection"
        }
    }
}

private extension LLMChatPanel {
    private var canSendMessage: Bool {
        (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty) && !isStreaming
    }

    private var formattedTokenEstimate: String {
        let estimate = ChatAttachmentPolicy.estimatedTokens(
            prompt: prompt,
            attachments: pendingAttachments.map(\.metadata)
        )
        return estimate.formatted(.number.notation(.compactName))
    }

    private func queueSendMessage() {
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

        Task {
            await sendMessage(text: text, attachments: pendingAttachments)
        }
    }

    private func sendMessage(text: String, attachments: [PendingChatAttachment]) async {
        guard !text.isEmpty || !attachments.isEmpty else { return }

        if attachments.contains(where: { $0.metadata.type == .image }),
           !selectedProviderID.nativeImageInput {
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
                        provider: selectedProviderID
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
            scope: scope,
            scopeLabel: scopeLabel,
            currentDocumentID: appState.selectedDocument?.id,
            selection: appState.selectedText,
            variantID: "terse-v1",
            userPrompt: text
        )

        isStreaming = true
        await sendAgentMessage(agentPrompt, images: imageAttachments, context: context)
        persistTranscript()
        isStreaming = false
    }

    private func loadTranscript() {
        guard messages.isEmpty, let vaultRoot = appState.currentVault?.rootURL else { return }
        do {
            messages = try ChatTranscriptStore.load(vaultRoot: vaultRoot)
        } catch {
            appState.errorMessage = "Failed to load chat transcript: \(error.localizedDescription)"
        }
    }

    private func persistTranscript() {
        guard let vaultRoot = appState.currentVault?.rootURL else { return }
        do {
            try ChatTranscriptStore.save(messages: messages, vaultRoot: vaultRoot)
        } catch {
            appState.errorMessage = "Failed to save chat transcript: \(error.localizedDescription)"
        }
    }

    private func openAttachmentImporter() {
        isAttachmentImporterPresented = true
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addAttachmentURLs(urls)
        case .failure(let error):
            showAttachmentError(error.localizedDescription)
        }
    }

    private func addAttachmentURLs(_ urls: [URL]) {
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

    private func removeAttachment(id: UUID) {
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

    /// Conservative context-window budget per provider, used to size the
    /// `ContextBuilder` instructions. Mirrors the `maxContextTokens` defaults of
    /// each backend's own context budget so the session path selects the
    /// same context tier the `AgentLoop` path did.
    private func contextBudget(for provider: LLMProviderID) -> Int {
        switch provider {
        case .foundationModels: return 4_000
        case .anyLanguageModel: return 8_192
        case .openAI: return 128_000
        case .anthropic: return 200_000
        }
    }

    /// Produce an `AgentEvent` stream via the FoundationModels session path
    /// (`SessionAgentRunner` + `LanguageModelFactory` + `buildInstructions`)
    /// and render it. The session owns the agentic tool loop; this panel only
    /// translates events into chat bubbles.
    private func sendAgentMessage(
        _ text: String,
        images: [SessionImageAttachment] = [],
        context: MessageContext
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
                for: selectedProviderID,
                keychain: appState.keychainService,
                config: factoryConfig
            )

            // Build instructions (system prompt + tiered vault excerpts) exactly
            // as the old AgentLoop path did, via the shared ContextBuilder.
            let contextBuilder = ContextBuilder(searchService: searchIndex, repository: repository)
            let instructions = try await contextBuilder.buildInstructions(
                prompt: text,
                scope: scope,
                currentDocumentID: appState.selectedDocument?.id,
                maxTokens: contextBudget(for: selectedProviderID),
                vaultName: appState.currentVault?.name ?? "Vault"
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
            if let sel = appState.selectedText, !sel.isEmpty {
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

            // Index of the current assistant text bubble being appended to. nil after a tool
            // call, which forces the next textToken to start a fresh bubble — so tool calls
            // visually break up the assistant's narration.
            var currentAssistantIndex: Int?

            for try await event in stream {
                switch event {
                case .textToken(let token):
                    if let idx = currentAssistantIndex {
                        messages[idx].content += token
                    } else {
                        messages.append(ChatMessage(
                            role: .assistant,
                            content: token,
                            context: context,
                            providerID: selectedProviderID
                        ))
                        currentAssistantIndex = messages.count - 1
                    }
                case .toolStart(let name, let args):
                    let info = ToolCallInfo(name: name, arguments: args)
                    messages.append(ChatMessage(role: .tool, content: "", toolCall: info))
                    currentAssistantIndex = nil
                case .toolEnd(let name, let result):
                    if let idx = messages.lastIndex(where: {
                        $0.role == .tool && $0.toolCall?.name == name && $0.toolCall?.isInFlight == true
                    }), var info = messages[idx].toolCall {
                        info.output = result.content
                        info.isError = result.isError
                        info.isInFlight = false
                        messages[idx].toolCall = info
                    }
                case .error(let err):
                    messages.append(ChatMessage(role: .assistant, content: "*Agent error: \(err)*", context: context))
                    currentAssistantIndex = nil
                case .done, .agentStart, .turnStart, .turnEnd:
                    break
                }
            }
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "*Error: \(error.localizedDescription)*", context: context))
            persistTranscript()
        }
    }

    private func saveAsNote(_ content: String) async {
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

    private func reportIssueCopy(_ message: ChatMessage) async {
        guard let report = await buildReport(for: message) else { return }
        IssueReporter.copyToClipboard(report)
        appState.errorMessage = "Issue report copied to clipboard."
    }

    private func reportIssueSave(_ message: ChatMessage) async {
        guard let report = await buildReport(for: message) else { return }
        do {
            let url = try IssueReporter.save(report)
            appState.errorMessage = "Issue saved to \(url.path)"
        } catch {
            appState.errorMessage = "Failed to save issue: \(error.localizedDescription)"
        }
    }
}

#Preview("Chat Panel — With Messages") {
    LLMChatPanel()
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 350, height: 600)
}

#Preview("Chat Panel — Empty") {
    LLMChatPanel()
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 350, height: 600)
}
