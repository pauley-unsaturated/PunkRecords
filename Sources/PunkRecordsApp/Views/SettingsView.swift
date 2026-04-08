import SwiftUI
import PunkRecordsCore
import PunkRecordsInfra

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var openAIBaseURL = "https://api.openai.com/v1"
    @State private var showSaveConfirmation = false
    private let keychainService = KeychainService()

    var body: some View {
        TabView {
            Tab("LLM Providers", systemImage: "brain") {
                providersTab
            }
        }
        .frame(width: 500, height: 300)
    }

    private var providersTab: some View {
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

#Preview("Settings") {
    SettingsView()
}
