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
            Tab("Local LLMs", systemImage: "desktopcomputer") {
                LocalProvidersSettingsView()
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
                    .help("For local servers, use the Local LLMs tab instead.")
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

// MARK: - Local LLMs

/// Connection + model settings for the local LLM providers (Ollama, LM Studio).
/// Each provider gets an endpoint field, a "Test connection" probe that lists
/// available models, a model picker, and a short benchmark of the chosen model.
private struct LocalProvidersSettingsView: View {
    var body: some View {
        Form {
            LocalProviderSection(providerID: .ollama)
            LocalProviderSection(providerID: .lmStudio)
        }
        .formStyle(.grouped)
    }
}

private struct LocalProviderSection: View {
    let providerID: LLMProviderID

    @AppStorage private var endpoint: String
    @AppStorage private var selectedModel: String

    @State private var status: Status = .idle
    @State private var models: [LocalModel] = []
    @State private var benchmark: InferenceStats?
    @State private var isBenchmarking = false

    enum Status: Equatable {
        case idle
        case checking
        case reachable(Int)        // model count
        case failed(String)
    }

    init(providerID: LLMProviderID) {
        self.providerID = providerID
        switch providerID {
        case .ollama:
            _endpoint = AppStorage(wrappedValue: LocalProviderSettings.defaultOllamaEndpoint,
                                   LocalProviderSettings.ollamaEndpointKey)
            _selectedModel = AppStorage(wrappedValue: "", LocalProviderSettings.ollamaModelKey)
        default:
            _endpoint = AppStorage(wrappedValue: LocalProviderSettings.defaultLMStudioEndpoint,
                                   LocalProviderSettings.lmStudioEndpointKey)
            _selectedModel = AppStorage(wrappedValue: "", LocalProviderSettings.lmStudioModelKey)
        }
    }

    var body: some View {
        Section(providerID.displayName) {
            HStack {
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: endpoint) {
                        NotificationCenter.default.post(name: LocalProviderSettings.didChangeNotification, object: nil)
                    }
                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(status == .checking)
            }

            statusRow

            if !models.isEmpty {
                Picker("Model", selection: $selectedModel) {
                    Text("None").tag("")
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: selectedModel) {
                    NotificationCenter.default.post(name: LocalProviderSettings.didChangeNotification, object: nil)
                }

                Button {
                    Task { await runBenchmark() }
                } label: {
                    if isBenchmarking {
                        Label("Benchmarking…", systemImage: "hourglass")
                    } else {
                        Label("Benchmark selected model", systemImage: "speedometer")
                    }
                }
                .disabled(selectedModel.isEmpty || isBenchmarking)

                if let benchmark, benchmark.hasAnyMetric {
                    benchmarkRow(benchmark)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .idle:
            Text("Not tested yet.").font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                .font(.caption).foregroundStyle(.secondary)
        case .reachable(let count):
            Label("Connected — \(count) model\(count == 1 ? "" : "s") available",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func benchmarkRow(_ stats: InferenceStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ttft = stats.timeToFirstToken {
                Text("Time to first token: \(InferenceStatsView.formatSeconds(ttft))")
            }
            if let prefill = stats.prefillRate {
                Text("Prefill: \(InferenceStatsView.formatRate(prefill)) tok/s")
            }
            if let tps = stats.tokensPerSecond {
                Text("Generation: \(InferenceStatsView.formatRate(tps)) tok/s")
            }
            if let load = stats.loadDuration {
                Text("Model load: \(InferenceStatsView.formatSeconds(load))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func makeProvider() -> any LocalModelProvider {
        let url = URL(string: endpoint) ?? LocalProviderSettings.endpoint(for: providerID)
        switch providerID {
        case .ollama: return OllamaProvider(endpoint: url, modelID: selectedModel)
        default: return LMStudioProvider(endpoint: url, modelID: selectedModel)
        }
    }

    private func testConnection() async {
        status = .checking
        benchmark = nil
        let result = await makeProvider().validate()
        if result.isReachable {
            models = result.models
            status = .reachable(result.models.count)
            if selectedModel.isEmpty, let first = result.models.first {
                selectedModel = first.id
            }
        } else {
            models = []
            status = .failed(result.errorMessage ?? "Unreachable")
        }
    }

    private func runBenchmark() async {
        isBenchmarking = true
        defer { isBenchmarking = false }
        benchmark = await makeProvider().benchmark(prompt: "Reply with a one-sentence greeting.")
    }
}

#Preview("Settings") {
    SettingsView()
}
