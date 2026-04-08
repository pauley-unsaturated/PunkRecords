import SwiftUI
import PunkRecordsCore

/// A single vault window. Each open KB gets its own instance with its own AppState.
struct VaultWindow: View {
    let vaultURL: URL
    @State private var appState = AppState()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationSplitView {
            VaultBrowserView()
        } detail: {
            HStack(spacing: 0) {
                if let docID = appState.selectedDocumentID {
                    VStack(spacing: 0) {
                        RawEditorView(documentID: docID)

                        if appState.isBacklinksPanelVisible {
                            Divider()
                            BacklinksPanel(documentID: docID)
                                .frame(height: 180)
                                .accessibilityIdentifier("backlinksPanel")
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Note Selected",
                        systemImage: "doc.text",
                        description: Text("Select a note from the sidebar or create a new one with \u{2318}N")
                    )
                }

                if appState.isChatPanelVisible {
                    Divider()
                    LLMChatPanel()
                        .accessibilityIdentifier("chatPanel")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.isSearchPresented },
            set: { appState.isSearchPresented = $0 }
        )) {
            SearchView()
        }
        .environment(appState)
        .navigationTitle(appState.currentVault?.name ?? "PunkRecords")
        .task {
            let url: URL
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                url = Self.createUITestVault()
            } else if let envPath = ProcessInfo.processInfo.environment["PUNK_RECORDS_TEST_VAULT"] {
                url = URL(fileURLWithPath: envPath)
            } else {
                url = vaultURL
            }
            await appState.openVault(at: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowCreateNote)) { _ in
            appState.createNewNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowFindInVault)) { _ in
            appState.isSearchPresented = true
        }
    }
}

// MARK: - Menu Command Forwarding

extension Notification.Name {
    static let vaultWindowCreateNote = Notification.Name("vaultWindowCreateNote")
    static let vaultWindowFindInVault = Notification.Name("vaultWindowFindInVault")
}

// MARK: - UI Testing Support

extension VaultWindow {
    static func createUITestVault() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PunkRecords-UITest")
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let note = """
        ---
        id: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
        title: Test Note
        tags: [testing]
        ---

        # Test Note

        This is a test note with **bold text** and a [[wikilink]].

        Select this text to test Ask AI.
        """
        try? note.write(to: tempDir.appendingPathComponent("test-note.md"),
                       atomically: true, encoding: .utf8)
        return tempDir
    }
}
