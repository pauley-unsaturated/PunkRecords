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
        .frame(width: 520, height: 340)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("chatProviderID") private var chatProviderRaw = LLMProviderID.anthropic.rawValue
    @AppStorage("webSearchEnabled") private var webSearchEnabled = false

    var body: some View {
        Form {
            Section("AI") {
                Picker("Default provider", selection: $chatProviderRaw) {
                    ForEach(LLMProviderID.allCases, id: \.rawValue) { id in
                        Text(id.displayName).tag(id.rawValue)
                    }
                }
                Toggle("Enable web search in chat", isOn: $webSearchEnabled)
                    .help("Lets the assistant fetch and cite web pages when a provider supports it.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProvidersSettingsTab: View {
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var openAIBaseURL = "https://api.openai.com/v1"
    @State private var showSaveConfirmation = false
    private let keychainService = KeychainService()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .onAppear {
                        anthropicKey = (try? keychainService.apiKey(for: "anthropic")) ?? ""
                    }
            }

            Section("OpenAI / Compatible") {
                SecureField("API Key", text: $openAIKey)
                    .onAppear {
                        openAIKey = (try? keychainService.apiKey(for: "openai")) ?? ""
                    }
                TextField("Base URL", text: $openAIBaseURL)
                    .help("Use http://localhost:11434/v1 for Ollama, http://localhost:1234/v1 for LM Studio")
            }

            Section {
                Button("Save") {
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
        try? keychainService.setAPIKey(anthropicKey, for: "anthropic")
        try? keychainService.setAPIKey(openAIKey, for: "openai")
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
