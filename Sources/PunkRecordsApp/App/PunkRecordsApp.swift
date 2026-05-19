import SwiftUI
import AppKit
import PunkRecordsCore

@main
struct PunkRecordsApp: App {
    @State private var recentsStore = RecentVaultsStore()
    @Environment(\.openWindow) private var openWindow

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
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export as HTML…") {
                    NotificationCenter.default.post(name: .vaultWindowExportHTML, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Filter Sidebar") {
                    NotificationCenter.default.post(name: .vaultWindowFocusSidebarSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                // ⌘⌥⇧F to leave ⌘⌥F available for NSTextView's standard
                // Find-and-Replace bar (the in-editor find acceptance for W5).
                Button("Find by Content…") {
                    NotificationCenter.default.post(name: .vaultWindowFindInVault, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
