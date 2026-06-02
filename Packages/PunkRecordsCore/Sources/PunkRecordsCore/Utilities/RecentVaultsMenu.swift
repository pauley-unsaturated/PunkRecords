import Foundation

/// A vault the user has opened before, as surfaced in the
/// "File ▸ Open Recent" menu and the Welcome window's recents list.
///
/// Lives in Core (rather than the app target) so the menu's ordering,
/// de-duplication, and cap logic can be unit-tested without the SwiftUI
/// layer. The stored shape (`name`, `url`, `lastOpened`) is also the
/// persisted shape — `RecentVaultsStore` round-trips `[RecentVaultEntry]`
/// through `UserDefaults`.
public struct RecentVaultEntry: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity derived from the vault URL, so the same vault never
    /// appears twice in a `ForEach`.
    public var id: String { url.absoluteString }
    public let name: String
    public let url: URL
    public let lastOpened: Date

    public init(name: String, url: URL, lastOpened: Date) {
        self.name = name
        self.url = url
        self.lastOpened = lastOpened
    }
}

/// Pure logic for the "File ▸ Open Recent" submenu.
///
/// The menu wants a specific view of the recents list: most-recently-opened
/// first, one entry per vault (de-duplicated by standardized URL), capped to a
/// small number. Keeping that here — rather than inline in the SwiftUI command
/// builder — lets us unit-test the ordering, de-duplication, and cap.
public enum RecentVaultsMenu {
    /// Number of vaults shown in the menu — matches the macOS "Open Recent"
    /// convention and the store's own retention cap.
    public static let defaultLimit = 10

    /// The entries to display, most-recent-first, de-duplicated by standardized
    /// vault URL (keeping the most recent open of each), capped to `limit`.
    /// A non-positive `limit` returns an empty array.
    public static func menuEntries(
        from recents: [RecentVaultEntry],
        limit: Int = defaultLimit
    ) -> [RecentVaultEntry] {
        guard limit > 0 else { return [] }

        let sorted = recents.sorted { $0.lastOpened > $1.lastOpened }
        var seen = Set<String>()
        var result: [RecentVaultEntry] = []
        result.reserveCapacity(min(limit, sorted.count))
        for entry in sorted {
            let key = entry.url.standardizedFileURL.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }
}
