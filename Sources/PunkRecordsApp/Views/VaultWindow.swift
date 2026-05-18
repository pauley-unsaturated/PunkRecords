import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
                if let doc = appState.selectedDocument {
                    VStack(spacing: 0) {
                        RawEditorView(documentPath: doc.path)

                        if appState.isBacklinksPanelVisible {
                            Divider()
                            BacklinksPanel(documentID: doc.id)
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
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowExportHTML)) { _ in
            Task { @MainActor in await exportCurrentDocumentAsHTML() }
        }
    }

    /// Renders the currently-selected note to a self-contained HTML file
    /// and presents NSSavePanel for the destination. No-op if no doc is
    /// selected. Errors surface via AppState.errorMessage.
    @MainActor
    private func exportCurrentDocumentAsHTML() async {
        guard let doc = appState.selectedDocument else {
            appState.errorMessage = "Select a note before exporting."
            return
        }

        let html = MarkdownHTMLRenderer.renderHTMLDocument(
            markdown: doc.content,
            title: doc.title
        )

        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.nameFieldStringValue = "\(FilenameHelpers.sanitizeFilename(doc.title)).html"
        if let htmlType = UTType(filenameExtension: "html") {
            panel.allowedContentTypes = [htmlType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.errorMessage = "Failed to export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Menu Command Forwarding

extension Notification.Name {
    static let vaultWindowCreateNote = Notification.Name("vaultWindowCreateNote")
    static let vaultWindowFindInVault = Notification.Name("vaultWindowFindInVault")
    static let vaultWindowFocusSidebarSearch = Notification.Name("vaultWindowFocusSidebarSearch")
    static let vaultWindowExportHTML = Notification.Name("vaultWindowExportHTML")
}

// MARK: - UI Testing Support

extension VaultWindow {
    static func createUITestVault() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PunkRecords-UITest")
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let testNote = """
        ---
        id: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
        title: Test Note
        tags: [testing]
        ---

        # Test Note

        This is a test note with **bold text** and a [[wikilink]].

        Select this text to test Ask AI.
        """
        try? testNote.write(to: tempDir.appendingPathComponent("test-note.md"),
                            atomically: true, encoding: .utf8)

        // Second note so destructive-flow tests can delete one without
        // leaving the vault empty (which would change other tests' setUp).
        let scratch = """
        ---
        id: BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF
        title: Scratch Note
        tags: [testing]
        ---

        # Scratch Note

        Disposable note for delete-flow UI tests.
        """
        try? scratch.write(to: tempDir.appendingPathComponent("scratch-note.md"),
                           atomically: true, encoding: .utf8)

        return tempDir
    }
}
