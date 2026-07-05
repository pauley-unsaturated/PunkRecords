import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

/// Thin chat panel shell: rendering, composer bindings, provider/scope pickers,
/// keyboard shortcuts, and focus. All orchestration — the send pipeline,
/// provider/model resolution, tool construction, `AgentEvent` streaming,
/// transcript persistence, and error state — lives in ``ChatSessionController``.
struct LLMChatPanel: View {
    @Environment(AppState.self) private var appState
    @State private var controller: ChatSessionController
    @State private var scope: QueryScope = .global
    @AppStorage(ProviderRegistry.DefaultsKey.chatProvider)
    private var chatProviderRaw: String = ProviderRegistry.chatProviderDefault.rawValue

    init(appState: AppState) {
        _controller = State(initialValue: ChatSessionController(appState: appState))
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
                controller.loadTranscript()

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
                                        onReportIssueSave: { Task { await controller.reportIssueSave(message) } }
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
    }

    private var chatComposer: some View {
        @Bindable var controller = controller

        return VStack(alignment: .leading, spacing: 8) {
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
    LLMChatPanel(appState: PreviewData.makePreviewAppState())
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 350, height: 600)
}

#Preview("Chat Panel — Empty") {
    LLMChatPanel(appState: PreviewData.makePreviewAppState())
        .environment(PreviewData.makePreviewAppState())
        .frame(width: 350, height: 600)
}
