import SwiftUI
import PunkRecordsCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        if appState.currentVault != nil {
            NavigationSplitView {
                VaultBrowserView()
            } detail: {
                HStack(spacing: 0) {
                    if let docID = appState.selectedDocumentID {
                        RawEditorView(documentID: docID)
                    } else {
                        ContentUnavailableView(
                            "No Note Selected",
                            systemImage: "doc.text",
                            description: Text("Select a note from the sidebar or create a new one with ⌘N")
                        )
                    }

                    if appState.isChatPanelVisible {
                        Divider()
                        LLMChatPanel()
                            .accessibilityIdentifier("chatPanel")
                    }
                }
            }
            .sheet(isPresented: $appState.isSearchPresented) {
                SearchView()
            }
        } else {
            VaultPickerView()
        }
    }
}

#Preview("Vault Picker") {
    VaultPickerView()
        .environment(AppState())
}

#Preview("No Note Selected") {
    ContentView()
        .environment({
            let state = PreviewData.makePreviewAppState()
            state.selectedDocumentID = nil
            return state
        }())
        .frame(width: 900, height: 600)
}

#Preview("With Chat Panel") {
    ContentView()
        .environment({
            let state = PreviewData.makePreviewAppState()
            state.selectedDocumentID = nil
            state.isChatPanelVisible = true
            return state
        }())
        .frame(width: 900, height: 600)
}

struct VaultPickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("PunkRecords")
                .font(.largeTitle.bold())

            Text("Open a vault folder to get started")
                .foregroundStyle(.secondary)

            Button("Open Vault") {
                openVault()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func openVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for your knowledge base"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await appState.openVault(at: url)
        }
    }
}
