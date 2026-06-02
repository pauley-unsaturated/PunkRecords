import Foundation
import PunkRecordsCore

/// Persists recently opened vault locations via UserDefaults.
@MainActor
@Observable
final class RecentVaultsStore {
    private static let key = "recentVaults"
    private static let maxRecents = 10

    /// The recent-vault value type lives in Core (as `RecentVaultEntry`) so the
    /// menu's ordering/de-dup/cap logic is unit-testable; this alias keeps the
    /// existing `RecentVaultsStore.RecentVault` call sites working.
    typealias RecentVault = RecentVaultEntry

    private(set) var recents: [RecentVault] = []

    /// Entries for the "File ▸ Open Recent" submenu — most-recent-first,
    /// de-duplicated, and capped. See ``RecentVaultsMenu``.
    var menuEntries: [RecentVault] {
        RecentVaultsMenu.menuEntries(from: recents)
    }

    init() {
        load()
    }

    func recordOpen(_ url: URL) {
        var list = recents.filter { $0.url.standardizedFileURL != url.standardizedFileURL }
        let entry = RecentVault(
            name: url.lastPathComponent,
            url: url.standardizedFileURL,
            lastOpened: Date()
        )
        list.insert(entry, at: 0)
        if list.count > Self.maxRecents {
            list = Array(list.prefix(Self.maxRecents))
        }
        recents = list
        save()
    }

    func remove(_ vault: RecentVault) {
        recents.removeAll { $0.id == vault.id }
        save()
    }

    func clearAll() {
        recents = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([RecentVault].self, from: data) else {
            return
        }
        // Filter out vaults whose directories no longer exist
        recents = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
