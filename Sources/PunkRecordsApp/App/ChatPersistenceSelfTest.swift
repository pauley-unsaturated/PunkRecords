#if DEBUG
import Foundation
import PunkRecordsCore

/// Headless diagnostic for PUNK-b51 ("nothing is getting saved"): drives the
/// REAL AppState → ChatSessionController → thread-store path against a vault
/// directory passed on the command line, printing each step, then simulates a
/// relaunch with a fresh AppState over the same directory. Debug builds only.
///
///     PunkRecords.app/Contents/MacOS/PunkRecords \
///         --chat-persistence-selftest /path/to/scratch-vault
@MainActor
enum ChatPersistenceSelfTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "--chat-persistence-selftest"),
              args.indices.contains(flagIndex + 1) else { return }
        let vaultURL = URL(fileURLWithPath: args[flagIndex + 1])

        Task { @MainActor in
            var failures = 0
            func check(_ condition: Bool, _ label: String) {
                print("SELFTEST \(condition ? "PASS" : "FAIL"): \(label)")
                if !condition { failures += 1 }
            }

            print("SELFTEST vault: \(vaultURL.path)")

            let appState = AppState()
            await appState.openVault(at: vaultURL)
            guard let controller = appState.chatController else {
                print("SELFTEST FAIL: no chatController after openVault")
                exit(1)
            }
            await controller.loadInitialThread()
            let initialCount = controller.threadSummaries.count
            print("SELFTEST initial summaries: \(initialCount)")

            controller.messages.append(ChatMessage(role: .user, content: "selftest conversation one"))
            let savedA = await controller.persistActiveThread()
            check(savedA, "persist A reported success")
            check(controller.threadSummaries.count == initialCount + 1,
                  "A listed (have \(controller.threadSummaries.count))")

            await controller.newChat()
            check(controller.messages.isEmpty, "newChat cleared transcript")

            controller.messages.append(ChatMessage(role: .user, content: "selftest conversation two"))
            let savedB = await controller.persistActiveThread()
            check(savedB, "persist B reported success")
            check(controller.threadSummaries.count == initialCount + 2,
                  "A and B listed (have \(controller.threadSummaries.count))")

            let threadsDir = vaultURL.appendingPathComponent(VaultPaths.chatThreadsDirectory)
            let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: threadsDir.path))?
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix("embeddings") } ?? []
            print("SELFTEST files on disk: \(onDisk)")
            check(onDisk.count >= initialCount + 2, "thread files exist on disk")

            // Simulated relaunch: fresh AppState + controller over the same vault.
            let relaunch = AppState()
            await relaunch.openVault(at: vaultURL)
            await relaunch.chatController?.loadInitialThread()
            let relaunchCount = relaunch.chatController?.threadSummaries.count ?? -1
            check(relaunchCount == initialCount + 2,
                  "relaunch lists both (have \(relaunchCount))")

            print(failures == 0 ? "SELFTEST OVERALL PASS" : "SELFTEST OVERALL FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
