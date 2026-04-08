import SwiftUI
import PunkRecordsCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var openAIBaseURL = "https://api.openai.com/v1"
    @State private var showSaveConfirmation = false

    var body: some View {
        TabView {
            Tab("LLM Providers", systemImage: "brain") {
                providersTab
            }

            Tab("Vault", systemImage: "folder") {
                vaultTab
            }
        }
        .frame(width: 500, height: 350)
    }

    private var providersTab: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .onAppear {
                        anthropicKey = (try? appState.keychainService.apiKey(for: "anthropic")) ?? ""
                    }
            }

            Section("OpenAI / Compatible") {
                SecureField("API Key", text: $openAIKey)
                    .onAppear {
                        openAIKey = (try? appState.keychainService.apiKey(for: "openai")) ?? ""
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

    private var vaultTab: some View {
        Form {
            if let vault = appState.currentVault {
                Section("Current Vault") {
                    LabeledContent("Name", value: vault.name)
                    LabeledContent("Path", value: vault.rootURL.path)
                }
            } else {
                ContentUnavailableView("No Vault Open", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
    }

}

#Preview("Settings") {
    SettingsView()
        .environment(PreviewData.makePreviewAppState())
}

private extension SettingsView {
    func saveKeys() {
        try? appState.keychainService.setAPIKey(anthropicKey, for: "anthropic")
        try? appState.keychainService.setAPIKey(openAIKey, for: "openai")
    }
}
