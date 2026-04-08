import SwiftUI
import AppKit
import PunkRecordsCore

@main
struct PunkRecordsApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    // Ensure the app activates (needed for UI testing)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .task {
                    if let vaultPath = ProcessInfo.processInfo.environment["PUNK_RECORDS_TEST_VAULT"] {
                        await appState.openVault(at: URL(fileURLWithPath: vaultPath))
                    } else if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                        // Create a temp vault inside the app's own writable space
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
                        await appState.openVault(at: tempDir)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    appState.createNewNote()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Vault") {
                    appState.isSearchPresented = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
