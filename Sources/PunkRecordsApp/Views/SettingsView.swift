import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab()
            }
            Tab("Providers", systemImage: "brain") {
                ProvidersSettingsTab()
            }
            Tab("Editor", systemImage: "textformat") {
                EditorSettingsTab()
            }
            Tab("Keyboard", systemImage: "keyboard") {
                KeyboardSettingsTab()
            }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(ProviderRegistry.DefaultsKey.chatProvider)
    private var chatProviderRaw = ProviderRegistry.chatProviderDefault.rawValue

    var body: some View {
        Form {
            Section("AI") {
                Picker("Provider", selection: $chatProviderRaw) {
                    ForEach(LLMProviderID.allCases, id: \.rawValue) { id in
                        Text(id.displayName).tag(id.rawValue)
                    }
                }
                .help("Backs chat and note compilation alike. The chat panel's "
                    + "picker changes this same selection.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProvidersSettingsTab: View {
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var showSaveConfirmation = false
    // Endpoint config persists immediately (no key to store), so it lives in
    // AppStorage and is shared with the chat panel / model factory via the
    // same keys. Empty OpenAI base URL means the official endpoint.
    @AppStorage(ProviderRegistry.DefaultsKey.ollamaModel)
    private var ollamaModel = ProviderRegistry.defaultOllamaModel
    @AppStorage(ProviderRegistry.DefaultsKey.ollamaBaseURL)
    private var ollamaBaseURL = ProviderRegistry.defaultOllamaBaseURL
    @AppStorage(ProviderRegistry.DefaultsKey.openAIBaseURL)
    private var openAIBaseURL = ProviderRegistry.defaultOpenAIBaseURL
    private let keychainService = KeychainService()

    var body: some View {
        Form {
            Section("Local — Ollama (on-device, no key)") {
                TextField("Model", text: $ollamaModel)
                    .help("Ollama model name. qwen3 has the most reliable tool calling; "
                        + "gemma4 also works. Run `ollama pull <model>` first.")
                TextField("Server URL", text: $ollamaBaseURL)
                    .help("Default http://localhost:11434. Start the server with `ollama serve`.")
                Text("The provider lights up in chat once the Ollama server is reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude — Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .onAppear {
                        anthropicKey = (try? keychainService.apiKey(for: ProviderRegistry.KeychainAccount.anthropic)) ?? ""
                    }
            }

            Section("OpenAI / Compatible") {
                SecureField("API Key", text: $openAIKey)
                    .onAppear {
                        openAIKey = (try? keychainService.apiKey(for: ProviderRegistry.KeychainAccount.openAI)) ?? ""
                    }
                TextField("Base URL (blank = api.openai.com)", text: $openAIBaseURL)
                    .help("Any OpenAI-compatible endpoint, e.g. http://localhost:1234/v1 for "
                        + "LM Studio. Leave blank for the official OpenAI API.")
            }

            Section("Apple Intelligence — on-device") {
                Text("Uses the built-in SystemLanguageModel. Available automatically when "
                    + "Apple Intelligence is enabled and the model has downloaded — no key needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Save API Keys") {
                    saveKeys()
                    showSaveConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .alert("Settings Saved", isPresented: $showSaveConfirmation) { }
    }

    private func saveKeys() {
        try? keychainService.setAPIKey(anthropicKey, for: ProviderRegistry.KeychainAccount.anthropic)
        try? keychainService.setAPIKey(openAIKey, for: ProviderRegistry.KeychainAccount.openAI)
    }
}

// MARK: - Editor

private struct EditorSettingsTab: View {
    @AppStorage("editor.themeID") private var themeID = EditorThemeCatalog.defaultID

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeID) {
                    ForEach(EditorThemeCatalog.all, id: \.id) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .help("Applies to the editor and preview. Changes take effect immediately.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

private struct KeyboardSettingsTab: View {
    @AppStorage("editor.emacsKeybindings") private var emacsKeybindings = false

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Emacs keybindings", isOn: $emacsKeybindings)
                    .help("Enables Emacs-style motion and editing chords (⌃A, ⌃E, ⌃K, …) in the editor.")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Settings") {
    SettingsView()
}
