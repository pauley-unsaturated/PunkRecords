import SwiftUI
import PunkRecordsCore

// ContentView is no longer the main app view — VaultWindow and WelcomeWindow
// handle the two main states. This file is kept for preview compatibility.

#Preview("Vault Window") {
    VaultWindow(vaultURL: PreviewData.previewVaultURL)
        .environment(RecentVaultsStore())
        .frame(width: 900, height: 600)
}

#Preview("Welcome Window") {
    WelcomeWindow()
        .environment(RecentVaultsStore())
}
