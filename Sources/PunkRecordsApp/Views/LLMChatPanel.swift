import SwiftUI
import PunkRecordsCore

struct LLMChatPanel: View {
    @Environment(AppState.self) private var appState
    @State private var prompt = ""
    @State private var messages: [ChatMessage] = []
    @State private var isStreaming = false
    @State private var scope: QueryScope = .global
    @State private var isAgentMode = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Chat")
                    .font(.headline)
                Spacer()
                Toggle("Agent", isOn: $isAgentMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("When enabled, the AI can search your vault, read documents, and create notes autonomously.")
                scopePicker
                Button("Close", systemImage: "xmark.circle.fill") {
                    appState.isChatPanelVisible = false
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ChatBubble(message: message) {
                                Task { await saveAsNote(message.content) }
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

    private var scopePicker: some View {
        Menu {
            Button("Entire KB") { scope = .global }
            if let docID = appState.selectedDocumentID {
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

        isStreaming = true
        var assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)

        if isAgentMode {
            await sendAgentMessage(text, orchestrator: orchestrator, assistantMessage: &assistantMessage)
        } else {
            await sendSimpleMessage(text, orchestrator: orchestrator, assistantMessage: &assistantMessage)
        }

        isStreaming = false
    }

    private func sendSimpleMessage(_ text: String, orchestrator: LLMOrchestrator, assistantMessage: inout ChatMessage) async {
        do {
            let stream = try await orchestrator.ask(
                prompt: text,
                selectedText: appState.selectedText,
                scope: scope,
                currentDocumentID: appState.selectedDocumentID
            )

            for try await event in stream {
                switch event {
                case .token(let token):
                    assistantMessage.content += token
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex] = assistantMessage
                    }
                case .done:
                    break
                case .citation, .error:
                    break
                }
            }
        } catch {
            assistantMessage.content += "\n\n*Error: \(error.localizedDescription)*"
            if let lastIndex = messages.indices.last {
                messages[lastIndex] = assistantMessage
            }
        }
    }

    private func sendAgentMessage(_ text: String, orchestrator: LLMOrchestrator, assistantMessage: inout ChatMessage) async {
        guard let repository = appState.repository,
              let searchIndex = appState.searchIndex else {
            assistantMessage.content = "Vault not loaded."
            if let lastIndex = messages.indices.last {
                messages[lastIndex] = assistantMessage
            }
            return
        }

        do {
            let provider = try await orchestrator.resolveProvider()
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
                currentDocumentID: appState.selectedDocumentID,
                selectedText: appState.selectedText
            )

            for try await event in stream {
                switch event {
                case .textToken(let token):
                    assistantMessage.content += token
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex] = assistantMessage
                    }
                case .toolStart(let name, _):
                    assistantMessage.content += "\n\n> Using tool: **\(name)**...\n"
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex] = assistantMessage
                    }
                case .toolEnd(let name, let result):
                    if result.isError {
                        assistantMessage.content += "> **\(name)** failed: \(result.content)\n\n"
                    } else {
                        assistantMessage.content += "> **\(name)** completed.\n\n"
                    }
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex] = assistantMessage
                    }
                case .error(let err):
                    assistantMessage.content += "\n\n*Agent error: \(err)*"
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex] = assistantMessage
                    }
                case .done, .agentStart, .turnStart, .turnEnd:
                    break
                }
            }
        } catch {
            assistantMessage.content += "\n\n*Error: \(error.localizedDescription)*"
            if let lastIndex = messages.indices.last {
                messages[lastIndex] = assistantMessage
            }
        }
    }

    private func saveAsNote(_ content: String) async {
        guard let compiler = appState.noteCompiler else { return }
        do {
            let doc = try await compiler.saveResponseAsNote(
                responseText: content,
                sourceDocumentID: appState.selectedDocumentID,
                folderPath: ""
            )
            appState.selectedDocumentID = doc.id
        } catch {
            appState.errorMessage = "Failed to save note: \(error.localizedDescription)"
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

    enum Role {
        case user, assistant
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let onSaveAsNote: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.content)
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
