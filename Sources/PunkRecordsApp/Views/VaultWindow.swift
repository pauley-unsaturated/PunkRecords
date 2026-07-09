import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PunkRecordsCore

/// A single vault window. Each open KB gets its own instance with its own AppState.
struct VaultWindow: View {
    let vaultURL: URL
    @State private var appState = AppState()
    @Environment(\.dismissWindow) private var dismissWindow

    /// The UI-testing vault is tiny and opens instantly, so the loading overlay
    /// would only be a sub-frame flash — and a window-covering overlay risks
    /// racing element queries. Suppress it under `--ui-testing` (same gate the
    /// `.task` below uses to pick the test vault).
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

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

                if appState.isChatPanelVisible, let controller = appState.chatController {
                    Divider()
                    LLMChatPanel(controller: controller)
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
        .sheet(isPresented: Binding(
            get: { appState.isQuickOpenPresented },
            set: { appState.isQuickOpenPresented = $0 }
        )) {
            QuickOpenView()
        }
        .sheet(isPresented: Binding(
            get: { appState.isRefilePresented },
            set: { appState.isRefilePresented = $0 }
        )) {
            RefileView()
        }
        .inspector(isPresented: Binding(
            get: { appState.isInspectorPresented },
            set: { appState.isInspectorPresented = $0 }
        )) {
            InspectorPanel()
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .sheet(isPresented: Binding(
            get: { !appState.pendingRecoveries.isEmpty },
            // Dismissing the sheet without choosing keeps the sidecars on disk
            // for the next launch; only Recover/Discard buttons resolve them.
            set: { if !$0 { appState.pendingRecoveries = [] } }
        )) {
            RecoverySheet()
        }
        .overlay {
            if appState.isLoading && !isUITesting {
                VaultOpenProgressView(progress: appState.openProgress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isLoading)
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
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowQuickOpen)) { _ in
            appState.isQuickOpenPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowRefile)) { _ in
            appState.beginRefile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowToggleInspector)) { _ in
            appState.isInspectorPresented.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWindowSummarizeClipboardURL)) { _ in
            // PUNK-ddq: the chat panel shows the progress row, so reveal it.
            appState.isChatPanelVisible = true
            appState.chatController?.summarizeURLFromClipboard(.fromUserDefaults())
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

// MARK: - Crash Recovery

/// Minimal recovery prompt shown on launch when crash-recovery sidecars hold
/// unsaved edits. Deliberately plain — a titled list with Recover/Discard per
/// note. The decision logic (which notes are recoverable) is the pure, tested
/// `RecoveryScan`; this view is a thin shell over `AppState.pendingRecoveries`.
/// Visual polish is out of scope and validated manually.
private struct RecoverySheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Recover unsaved changes?", systemImage: "arrow.uturn.backward.circle")
                .font(.headline)

            Text("PunkRecords found notes with unsaved edits from a previous session that ended unexpectedly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(appState.pendingRecoveries) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: candidate))
                            .font(.body)
                        if !candidate.noteExistsOnDisk {
                            Text("Original note is missing — recovering re-creates it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Discard", role: .destructive) {
                        Task { await appState.discardRecovery(candidate) }
                    }
                    Button("Recover") {
                        Task { await appState.recoverNote(candidate) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    /// Best-effort human-readable name for a recovery candidate: the first H1 in
    /// the recovered content, else a shortened id.
    private func title(for candidate: RecoveryCandidate) -> String {
        let derived = Document.deriveTitle(
            content: candidate.recoveredContent,
            frontmatter: [:],
            filename: "Recovered"
        )
        return derived.isEmpty ? "Note \(candidate.noteID.uuidString.prefix(8))" : derived
    }
}

// MARK: - Vault Open Progress

/// Centered overlay shown while a vault is opening so a long ingest doesn't
/// look like a frozen window. Determinate during indexing (a known note
/// count), indeterminate while reading notes off disk. All display strings and
/// the fraction come from the unit-tested ``VaultOpenProgress``.
private struct VaultOpenProgressView: View {
    let progress: VaultOpenProgress?

    private var label: String { progress?.label ?? "Opening vault…" }

    var body: some View {
        VStack(spacing: 14) {
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction) {
                    Text(label)
                }
                .frame(width: 240)
            } else {
                ProgressView {
                    Text(label)
                }
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vaultOpenProgress")
        .accessibilityLabel(label)
    }
}

// MARK: - Menu Command Forwarding

extension Notification.Name {
    static let vaultWindowCreateNote = Notification.Name("vaultWindowCreateNote")
    static let vaultWindowFindInVault = Notification.Name("vaultWindowFindInVault")
    static let vaultWindowFocusSidebarSearch = Notification.Name("vaultWindowFocusSidebarSearch")
    static let vaultWindowExportHTML = Notification.Name("vaultWindowExportHTML")
    static let vaultWindowQuickOpen = Notification.Name("vaultWindowQuickOpen")
    static let vaultWindowRefile = Notification.Name("vaultWindowRefile")
    static let vaultWindowToggleInspector = Notification.Name("vaultWindowToggleInspector")
    static let vaultWindowSummarizeClipboardURL = Notification.Name("vaultWindowSummarizeClipboardURL")
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

        // Notes for refile (⌘⇧M) UI tests. "Movable" has no inbound links
        // (direct move); "Linked Section" is referenced by Linker so refiling it
        // triggers the link-update dialog. Each note's last heading is the one a
        // caret-at-end lands in, keeping the tests deterministic.
        let refilePlain = """
        ---
        id: CCCCCCCC-0000-0000-0000-000000000001
        title: Refile Plain
        ---

        # Refile Plain

        ## Movable

        movable body
        """
        try? refilePlain.write(to: tempDir.appendingPathComponent("refile-plain.md"),
                               atomically: true, encoding: .utf8)

        let refileLinked = """
        ---
        id: CCCCCCCC-0000-0000-0000-000000000002
        title: Refile Linked
        ---

        # Refile Linked

        ## Linked Section

        linked body
        """
        try? refileLinked.write(to: tempDir.appendingPathComponent("refile-linked.md"),
                                atomically: true, encoding: .utf8)

        let refileDest = """
        ---
        id: CCCCCCCC-0000-0000-0000-000000000003
        title: Refile Dest
        ---

        # Refile Dest

        ## Bucket

        bucket body
        """
        try? refileDest.write(to: tempDir.appendingPathComponent("refile-dest.md"),
                              atomically: true, encoding: .utf8)

        let linker = """
        ---
        id: CCCCCCCC-0000-0000-0000-000000000004
        title: Linker
        ---

        # Linker

        see [[Refile Linked#Linked Section]] for details
        """
        try? linker.write(to: tempDir.appendingPathComponent("linker.md"),
                          atomically: true, encoding: .utf8)

        return tempDir
    }
}
