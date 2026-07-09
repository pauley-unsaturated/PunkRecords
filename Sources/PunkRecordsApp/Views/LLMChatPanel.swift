import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Thin chat panel shell: rendering, composer bindings, provider/scope pickers,
/// keyboard shortcuts, and focus. All orchestration — the send pipeline,
/// provider/model resolution, tool construction, `AgentEvent` streaming,
/// transcript persistence, and error state — lives in ``ChatSessionController``.
struct LLMChatPanel: View {
    @Environment(AppState.self) private var appState
    /// The shared controller, owned by ``AppState`` (PUNK-9ss) so the sidebar
    /// Chats section and this panel see one source of truth. Passed in rather
    /// than created here; a plain `let` still observes its `@Observable` state.
    let controller: ChatSessionController
    @State private var scope: QueryScope = .global
    @AppStorage(ProviderRegistry.DefaultsKey.chatProvider)
    private var chatProviderRaw: String = ProviderRegistry.chatProviderDefault.rawValue

    init(controller: ChatSessionController) {
        self.controller = controller
    }

    private var selectedProviderID: LLMProviderID {
        ProviderRegistry.chatProvider(from: chatProviderRaw)
    }

    /// Endpoint/model config sourced from Settings (the `@AppStorage` keys the
    /// Providers tab writes), used both to decide availability and to build the
    /// backing model for a turn. `fromUserDefaults` reads the same persisted
    /// keys through ``ProviderRegistry``, so the panel holds no parsing of its own.
    private var factoryConfig: LanguageModelFactory.Config {
        .fromUserDefaults()
    }

    /// Volatile per-turn inputs resolved from settings + live app state, handed
    /// to the controller's send pipeline.
    private var turnParameters: ChatTurnParameters {
        ChatTurnParameters(
            provider: selectedProviderID,
            config: factoryConfig,
            scope: scope,
            scopeLabel: scopeLabel,
            selectedText: appState.selectedText,
            currentDocumentID: appState.selectedDocument?.id,
            vaultName: appState.currentVault?.name ?? "Vault"
        )
    }

    var body: some View {
        @Bindable var controller = controller

        return VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                threadHeaderTitle
                Spacer()
                providerPicker
                scopePicker
                if controller.isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("chatSummarizingIndicator")
                }
                actionsMenu
                newChatButton
                Button("Close", systemImage: "xmark.circle.fill") {
                    appState.isChatPanelVisible = false
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(providerKeyboardShortcuts)
            // Keyed to the controller's identity: if AppState ever swaps in a new
            // controller while the panel stays on screen (same-vault reopen), the
            // task re-fires and wires the replacement's store instead of leaving
            // it silently unwired (PUNK-hdd).
            .task(id: ObjectIdentifier(controller)) {
                await controller.loadInitialThread()

                // Re-probe while the panel is open so a provider that comes online
                // after launch (e.g. you start `ollama serve`, or add an API key in
                // Settings) un-grays on its own without reopening the panel.
                while !Task.isCancelled {
                    await controller.refreshAvailableProviders(config: factoryConfig)
                    try? await Task.sleep(for: .seconds(4))
                }
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.messages) { message in
                            Group {
                                if message.role == .tool, let call = message.toolCall {
                                    ToolCallBubble(toolCall: call)
                                } else {
                                    ChatBubble(
                                        message: message,
                                        onSaveAsNote: { Task { await controller.saveAsNote(message.content) } },
                                        onReportIssueCopy: { Task { await controller.reportIssueCopy(message) } },
                                        onReportIssueSave: { Task { await controller.reportIssueSave(message) } },
                                        onFork: { Task { await controller.forkThread(at: message.id) } },
                                        onRewind: { controller.requestRewind(to: message.id) },
                                        isStreaming: controller.isStreaming,
                                        contextChip: controller.contextChip(for: message),
                                        onOpenContextNote: { controller.openNote(path: $0) }
                                    )
                                }
                            }
                            .id(message.id)
                        }

                        if ChatWaitingIndicator.shouldShow(isStreaming: controller.isStreaming, messages: controller.messages) {
                            ChatWaitingIndicatorView()
                                .id("chatWaitingIndicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: controller.messages.count) {
                    if let last = controller.messages.last {
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
                controller.prompt = "Regarding this selection:\n\n> \(text)\n\n"
                appState.askAIText = nil
                scope = .selection
            }
        }
        .fileImporter(
            isPresented: $controller.isAttachmentImporterPresented,
            allowedContentTypes: PendingChatAttachment.allowedContentTypes,
            allowsMultipleSelection: true,
            onCompletion: controller.handleAttachmentImport
        )
        .alert(controller.attachmentAlertTitle, isPresented: $controller.isShowingAttachmentError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.attachmentErrorMessage)
        }
        .alert("Large chat submission", isPresented: $controller.isShowingSendConfirmation) {
            Button("Send", role: .destructive) {
                controller.confirmDeferredSend(turnParameters)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message is estimated at \(controller.formattedTokenEstimate) tokens or includes a file larger than 20 MB.")
        }
        .alert("Image Provider Unsupported", isPresented: $controller.isShowingImageProviderAlert) {
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
        .sheet(isPresented: $controller.isShowingSummarySaveSheet) {
            SummarySaveSheet(controller: controller)
        }
        .confirmationDialog(
            "Rewind to this message?",
            isPresented: $controller.isShowingRewindConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rewind", role: .destructive) {
                Task { await controller.confirmRewind() }
            }
            .accessibilityIdentifier("chatRewindConfirm")
            Button("Cancel", role: .cancel) {
                controller.cancelRewind()
            }
        } message: {
            Text(controller.rewindConfirmationMessage)
        }
        .alert("Summary not saved", isPresented: $controller.isShowingSummaryFallback) {
            Button("Retry Save") { controller.retrySaveSummary() }
            Button("Copy to Clipboard") { controller.copySummaryToClipboard() }
            Button("Discard", role: .destructive) { controller.discardSummary() }
        } message: {
            Text("Your conversation summary is ready but hasn't been saved. Retry the save, copy it to the clipboard, or discard it.")
        }
    }

    /// Header identity for the ACTIVE conversation: its title, with a tappable
    /// focus-note chip beneath naming the note the chat is about (PUNK-9ss). The
    /// chip opens that note via the same selection-driven navigation the
    /// per-message chips use. Distinct from the composer banner, which reflects
    /// the NEXT turn's scope rather than what the conversation has been about.
    private var threadHeaderTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.activeThread?.title ?? ChatThreadHelpers.defaultTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("chatThreadTitle")
            focusNoteChip
        }
    }

    /// Tappable "doc.text <note title>" chip for the active thread's focus note.
    /// Shown whenever the active thread has a focus note; hidden otherwise.
    @ViewBuilder
    private var focusNoteChip: some View {
        if let focus = controller.activeThread?.focusNote {
            Button {
                controller.openNote(path: focus.path)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                    Text(focus.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open “\(focus.title)” — the note this conversation is about")
            .accessibilityIdentifier("chatThreadFocusNote")
        }
    }

    /// Header actions menu, trimmed to actions on the ACTIVE conversation now that
    /// the thread list + delete live in the sidebar Chats section. "Summarize to
    /// Note" stays. Positioned AFTER the provider picker so the provider picker
    /// remains the first menu button `ChatTurnUITests` reaches for.
    private var actionsMenu: some View {
        Menu {
            Button {
                controller.summarizeToNote(turnParameters)
            } label: {
                Label("Summarize to Note", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!controller.canSummarize)
            .accessibilityIdentifier("chatSummarizeToNote")
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .help("Actions for this conversation")
        .accessibilityIdentifier("chatActionsMenu")
    }

    private var newChatButton: some View {
        Button("New Chat", systemImage: "square.and.pencil") {
            Task { await controller.newChat() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Start a new chat")
        .accessibilityIdentifier("chatNewChatButton")
    }

    /// Banner naming the note the NEXT turn is scoped to, with the same open-note
    /// affordance as the per-message chip. Hidden for vault-wide scopes.
    @ViewBuilder
    private var contextBanner: some View {
        if let banner = controller.composerBanner(scope: scope) {
            Button {
                controller.openNote(path: banner.path)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text("Chatting about: \(banner.title)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open “\(banner.title)” — the note this chat is scoped to")
            .accessibilityIdentifier("chatContextBanner")
        }
    }

    private var chatComposer: some View {
        @Bindable var controller = controller

        return VStack(alignment: .leading, spacing: 8) {
            contextBanner

            // URL-summarize flow (PUNK-ddq): progress row while running, or the
            // "Summarize this URL" affordance when the composer holds a lone URL.
            if controller.urlSummaryPhase != nil {
                URLSummaryStatusView(controller: controller)
            } else if controller.composerSummarizableURL != nil {
                Button {
                    controller.summarizeURLFromComposer(.fromUserDefaults())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Summarize this URL into a note")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Fetch the page and save a cited summary note in Web/ — nothing is sent to the chat")
                .accessibilityIdentifier("chatSummarizeURLAffordance")
            }

            if !controller.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(controller.pendingAttachments) { attachment in
                            ChatAttachmentChip(metadata: attachment.metadata) {
                                controller.removeAttachment(id: attachment.id)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("chatAttachmentChips")
            }

            Text("Estimated: ~\(controller.formattedTokenEstimate) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Estimated tokens")
                .accessibilityValue(controller.formattedTokenEstimate)
                .accessibilityIdentifier("chatTokenEstimate")

            HStack(alignment: .bottom, spacing: 8) {
                Button("Attach File", systemImage: "paperclip", action: controller.openAttachmentImporter)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("A", modifiers: [.command, .shift])
                    .help("Attach files")
                    .accessibilityLabel("Attach File")
                    .accessibilityIdentifier("chatAttachButton")

                TextField("Ask about your vault...", text: $controller.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(queueSendMessage)

                Button("Send message", systemImage: "arrow.up.circle.fill", action: queueSendMessage)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .disabled(!controller.canSendMessage)
                    .accessibilityIdentifier("chatSendButton")
            }
        }
        .padding()
        .overlay {
            if controller.isAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Drop files to attach")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            controller.addAttachmentURLs(urls)
            return true
        } isTargeted: { isTargeted in
            controller.isAttachmentDropTargeted = isTargeted
        }
    }

    private func queueSendMessage() {
        controller.queueSend(turnParameters)
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
                        if !controller.availableProviders.contains(id) {
                            Text("(not configured)").foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!controller.availableProviders.contains(id))
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
            if controller.availableProviders.contains(id) {
                chatProviderRaw = id.rawValue
            }
        }
        .keyboardShortcut(key, modifiers: .command)
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

#Preview("Chat Panel — With Messages") {
    let state = PreviewData.makePreviewAppState()
    LLMChatPanel(controller: ChatSessionController(appState: state))
        .environment(state)
        .frame(width: 350, height: 600)
}

#Preview("Chat Panel — Empty") {
    let state = PreviewData.makePreviewAppState()
    LLMChatPanel(controller: ChatSessionController(appState: state))
        .environment(state)
        .frame(width: 350, height: 600)
}
