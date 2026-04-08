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
            CommandGroup(after: .textEditing) {
                Button("Find in Vault") {
                    NotificationCenter.default.post(name: .vaultWindowFindInVault, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
