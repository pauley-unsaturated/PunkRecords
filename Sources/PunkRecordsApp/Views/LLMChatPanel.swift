import SwiftUI
import MarkdownUI
import PunkRecordsCore

struct LLMChatPanel: View {
    @Environment(AppState.self) private var appState
    @State private var prompt = ""
    @State private var messages: [ChatMessage] = []
    @State private var isStreaming = false
    @State private var scope: QueryScope = .global
    @State private var availableProviders: [LLMProviderID] = []
    @State private var localModels: [LLMProviderID: [LocalModel]] = [:]
    @State private var isLoadingModels = false
    @AppStorage("webSearchEnabled") private var isWebSearchEnabled = false
    @AppStorage("chatProviderID") private var chatProviderRaw: String = LLMProviderID.anthropic.rawValue
    @AppStorage(LocalProviderSettings.ollamaModelKey) private var ollamaModel = ""
    @AppStorage(LocalProviderSettings.lmStudioModelKey) private var lmStudioModel = ""

    private var selectedProviderID: LLMProviderID {
        LLMProviderID(rawValue: chatProviderRaw) ?? .anthropic
    }

    /// The model currently selected for the active local provider (if any).
    private var selectedLocalModel: String {
        switch selectedProviderID {
        case .ollama: return ollamaModel
        case .lmStudio: return lmStudioModel
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Chat")
                    .font(.headline)
                Spacer()
                providerPicker
                if selectedProviderID.isLocal {
                    modelPicker
                }
                Toggle("Web", isOn: $isWebSearchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Let the AI search the web (Anthropic native web search).")
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
            .task { await refreshAvailableProviders() }

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

            // Input
            HStack {
                TextField("Ask about your vault...", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { Task { await sendMessage() } }

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStreaming)
                .accessibilityLabel("Send message")
            }
            .padding()
        }
        .frame(minWidth: 300, idealWidth: 350)
        .onChange(of: appState.askAIText) { _, newValue in
            if let text = newValue {
                prompt = "Regarding this selection:\n\n> \(text)\n\n"
                appState.askAIText = nil
                scope = .selection
            }
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
        .help("Choose the LLM provider for this conversation. \u{2318}1–5 to switch.")
        .accessibilityIdentifier("chatProviderPicker")
    }

    /// Model selector for the active local provider. Lists models advertised by
    /// the server; selecting one persists the choice and updates the live
    /// provider so the next message uses it.
    private var modelPicker: some View {
        let models = localModels[selectedProviderID] ?? []
        return Menu {
            if models.isEmpty {
                Text(isLoadingModels ? "Loading…" : "No models found")
            }
            ForEach(models) { model in
                Button {
                    Task { await selectLocalModel(model.id) }
                } label: {
                    HStack {
                        if model.id == selectedLocalModel { Image(systemName: "checkmark") }
                        Text(model.displayName)
                    }
                }
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refreshLocalModels(force: true) }
            }
        } label: {
            Label(selectedLocalModel.isEmpty ? "Select model" : selectedLocalModel,
                  systemImage: "shippingbox")
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .help("Choose which local model to run.")
        .accessibilityIdentifier("chatModelPicker")
        .task(id: selectedProviderID) { await refreshLocalModels(force: false) }
    }

    /// Hidden buttons that own keyboard shortcuts for provider switching.
    /// Placed inside `.background` so they receive shortcuts while the chat
    /// panel is focused but don't take visual space.
    private var providerKeyboardShortcuts: some View {
        ZStack {
            providerShortcutButton(.foundationModels, key: "1")
            providerShortcutButton(.anthropic, key: "2")
            providerShortcutButton(.openAI, key: "3")
            providerShortcutButton(.ollama, key: "4")
            providerShortcutButton(.lmStudio, key: "5")
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
        guard let orchestrator = appState.orchestrator else { return }
        availableProviders = await orchestrator.availableProviders()
    }

    /// Fetch the model list for the active local provider. `force` re-fetches
    /// even when we already have a cached list.
    private func refreshLocalModels(force: Bool) async {
        let id = selectedProviderID
        guard id.isLocal else { return }
        if !force, localModels[id]?.isEmpty == false { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        let models = await appState.localModels(for: id)
        localModels[id] = models
        // Auto-select the first model if none chosen yet, so the provider becomes
        // usable without an extra click.
        if selectedLocalModel.isEmpty, let first = models.first {
            await selectLocalModel(first.id)
        }
    }

    private func selectLocalModel(_ model: String) async {
        switch selectedProviderID {
        case .ollama: ollamaModel = model
        case .lmStudio: lmStudioModel = model
        default: return
        }
        await appState.setLocalModel(model, for: selectedProviderID)
        availableProviders = await appState.orchestrator?.availableProviders() ?? availableProviders
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

    private func sendMessage() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        prompt = ""

        guard let orchestrator = appState.orchestrator else {
            messages.append(ChatMessage(role: .assistant, content: "No LLM provider configured. Open Settings to add an API key."))
            return
        }

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
        await sendAgentMessage(text, orchestrator: orchestrator, context: context)
        isStreaming = false
    }

    private func sendAgentMessage(_ text: String, orchestrator: LLMOrchestrator, context: MessageContext) async {
        guard let repository = appState.repository,
              let searchIndex = appState.searchIndex else {
            messages.append(ChatMessage(role: .assistant, content: "Vault not loaded.", context: context))
            return
        }

        do {
            let provider = try await orchestrator.resolveProvider(selectedProviderID)
            let contextBuilder = ContextBuilder(searchService: searchIndex, repository: repository)
            let tools: [any AgentTool] = [
                VaultSearchTool(searchService: searchIndex),
                ReadDocumentTool(repository: repository),
                CreateNoteTool(repository: repository),
                ListDocumentsTool(repository: repository),
            ]

            let agentLoop = AgentLoop(
                provider: provider,
                contextBuilder: contextBuilder,
                tools: tools,
                vaultName: appState.currentVault?.name ?? "Vault"
            )

            let stream = await agentLoop.run(
                prompt: text,
                scope: scope,
                currentDocumentID: appState.selectedDocument?.id,
                selectedText: appState.selectedText,
                enableWebSearch: isWebSearchEnabled
            )

            // Index of the current assistant text bubble being appended to. nil after a tool
            // call, which forces the next textToken to start a fresh bubble — so tool calls
            // visually break up the assistant's narration.
            var currentAssistantIndex: Int? = nil

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
                case .done(_, let stats, _):
                    // Attach inference metrics to the last assistant bubble so the
                    // stats footer (local providers) renders under the response.
                    if let stats, let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                        messages[idx].stats = stats
                    }
                case .agentStart, .turnStart, .turnEnd:
                    break
                }
            }
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "*Error: \(error.localizedDescription)*", context: context))
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

// MARK: - Supporting Types

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date = Date()
    /// For assistant messages: snapshot of what the user did when submitting the
    /// triggering prompt. Used by the "Report Issue" flow to reconstruct context.
    var context: MessageContext? = nil
    /// Populated when role == .tool — the agent tool invocation this row represents.
    var toolCall: ToolCallInfo? = nil
    /// For assistant messages: which provider produced this output. Drives the
    /// "via Claude / GPT / Apple" attribution chip and lets future "rerun with
    /// a different model" actions know what to switch *from*.
    var providerID: LLMProviderID? = nil
    /// For assistant messages from a local provider: inference performance
    /// metrics, shown in the per-response footer.
    var stats: InferenceStats? = nil

    enum Role {
        case user, assistant, tool
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let onSaveAsNote: () -> Void
    let onReportIssueCopy: () -> Void
    let onReportIssueSave: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Group {
                if message.role == .assistant {
                    Markdown(message.content)
                        .markdownTheme(.gitHub)
                        .markdownTextStyle(\.text) { FontSize(.em(0.9)) }
                } else {
                    Text(message.content)
                }
            }
            .padding(10)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.15)
                    : Color.secondary.opacity(0.1),
                in: .rect(cornerRadius: 10)
            )
            .textSelection(.enabled)

            if message.role == .assistant && !message.content.isEmpty {
                HStack(spacing: 8) {
                    if let providerID = message.providerID {
                        Text("via \(providerID.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("messageProviderAttribution")
                    }

                    Button("Save as Note", systemImage: "doc.badge.plus") {
                        onSaveAsNote()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)

                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)

                    if message.context != nil {
                        Menu {
                            Button("Copy to Clipboard", systemImage: "doc.on.clipboard") {
                                onReportIssueCopy()
                            }
                            Button("Save to File", systemImage: "square.and.arrow.down") {
                                onReportIssueSave()
                            }
                        } label: {
                            Label("Report Issue", systemImage: "flag")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Capture this turn's context as a bug report")
                    }
                }

                if let stats = message.stats, stats.hasAnyMetric {
                    InferenceStatsView(stats: stats)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// Compact one-line footer showing local-LLM inference performance.
struct InferenceStatsView: View {
    let stats: InferenceStats

    var body: some View {
        HStack(spacing: 10) {
            ForEach(metrics, id: \.label) { metric in
                HStack(spacing: 3) {
                    Image(systemName: metric.icon)
                    Text(metric.value)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("inferenceStats")
        .help(stats.source == .ollamaNative
              ? "Server-reported metrics from Ollama"
              : "Client-measured metrics")
    }

    private var metrics: [(label: String, icon: String, value: String)] {
        var out: [(String, String, String)] = []
        if let ttft = stats.timeToFirstToken {
            out.append(("ttft", "timer", "TTFT \(Self.formatSeconds(ttft))"))
        }
        if let prefill = stats.prefillRate {
            out.append(("prefill", "arrow.down.to.line", "\(Self.formatRate(prefill)) prefill"))
        }
        if let tps = stats.tokensPerSecond {
            out.append(("tps", "speedometer", "\(Self.formatRate(tps)) tok/s"))
        }
        return out
    }

    static func formatRate(_ value: Double) -> String {
        String(format: value >= 100 ? "%.0f" : "%.1f", value)
    }

    static func formatSeconds(_ value: TimeInterval) -> String {
        if value < 1 { return String(format: "%.0fms", value * 1000) }
        return String(format: "%.2fs", value)
    }
}
