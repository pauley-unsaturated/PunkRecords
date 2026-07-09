import SwiftUI
import AppKit
import PunkRecordsCore

@main
struct PunkRecordsApp: App {
    @State private var recentsStore = RecentVaultsStore()

    init() {
        #if DEBUG
        ChatPersistenceSelfTest.runIfRequested()
        #endif
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("editor.emacsKeybindings") private var emacsKeybindings = false

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    var body: some Scene {
        // Welcome window — shown on launch and via Cmd+0
        Window("Welcome to PunkRecords", id: "welcome") {
            WelcomeWindow()
                .environment(recentsStore)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // Under UI testing, deterministically open a vault window
                    // (VaultWindow builds its own temp vault for `--ui-testing`)
                    // instead of relying on state restoration to reopen one.
                    if isUITesting {
                        openWindow(value: URL(fileURLWithPath: NSTemporaryDirectory()))
                        dismissWindow(id: "welcome")
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .keyboardShortcut("0")

        // Vault windows — one per open vault
        WindowGroup(for: URL.self) { $vaultURL in
            if let url = vaultURL {
                VaultWindow(vaultURL: url)
                    .environment(recentsStore)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .vaultWindowCreateNote, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Open Quickly…") {
                    NotificationCenter.default.post(name: .vaultWindowQuickOpen, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu("Open Recent") {
                    ForEach(recentsStore.menuEntries) { vault in
                        Button(vault.name) {
                            recentsStore.recordOpen(vault.url)
                            openWindow(value: vault.url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        recentsStore.clearAll()
                    }
                    .disabled(recentsStore.menuEntries.isEmpty)
                }
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export as HTML…") {
                    NotificationCenter.default.post(name: .vaultWindowExportHTML, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                // ⌘⇧F — vault-wide full-text search (the "Find in Workspace"
                // convention from Xcode/VS Code). Full-text/tag:/title: search
                // over the same index the agent uses.
                Button("Find in Vault…") {
                    NotificationCenter.default.post(name: .vaultWindowFindInVault, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                // Sidebar title filter is the lighter, navigation-scoped filter;
                // it moves to ⌘⌥⇧F now that ⌘⇧F drives full-text search. ⌘⌥F is
                // deliberately left free for NSTextView's standard in-editor
                // Find-and-Replace bar.
                Button("Filter Sidebar") {
                    NotificationCenter.default.post(name: .vaultWindowFocusSidebarSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
            CommandMenu("Editor") {
                Button("Refile Heading…") {
                    NotificationCenter.default.post(name: .vaultWindowRefile, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Show Inspector") {
                    NotificationCenter.default.post(name: .vaultWindowToggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Summarize URL from Clipboard") {
                    NotificationCenter.default.post(name: .vaultWindowSummarizeClipboardURL, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()
                Toggle("Emacs Keybindings", isOn: $emacsKeybindings)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
