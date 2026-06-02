import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("RecentVaultsMenu Tests")
struct RecentVaultsMenuTests {
    private func entry(_ name: String, _ path: String, _ t: TimeInterval) -> RecentVaultEntry {
        RecentVaultEntry(
            name: name,
            url: URL(fileURLWithPath: path),
            lastOpened: Date(timeIntervalSince1970: t)
        )
    }

    @Test("Entries are returned most-recently-opened first")
    func ordersByLastOpenedDescending() {
        let entries = [
            entry("A", "/Users/test/A", 100),
            entry("C", "/Users/test/C", 300),
            entry("B", "/Users/test/B", 200),
        ]
        let result = RecentVaultsMenu.menuEntries(from: entries)
        #expect(result.map(\.name) == ["C", "B", "A"])
    }

    @Test("Duplicate URLs collapse, keeping the most recent open")
    func dedupesKeepingMostRecent() {
        let entries = [
            entry("Older", "/Users/test/Vault", 100),
            entry("Newer", "/Users/test/Vault", 300),
        ]
        let result = RecentVaultsMenu.menuEntries(from: entries)
        #expect(result.count == 1)
        #expect(result.first?.name == "Newer")
    }

    @Test("De-duplication normalizes URLs (resolves . and ..)")
    func dedupesByStandardizedURL() {
        let entries = [
            entry("Canonical", "/Users/test/Vault", 200),
            entry("Dotted", "/Users/test/sub/../Vault", 100),
        ]
        let result = RecentVaultsMenu.menuEntries(from: entries)
        #expect(result.count == 1)
        #expect(result.first?.name == "Canonical")
    }

    @Test("Result is capped to the default limit, keeping the most recent")
    func capsToDefaultLimit() {
        let entries = (0..<20).map { entry("N\($0)", "/Users/test/N\($0)", TimeInterval($0)) }
        let result = RecentVaultsMenu.menuEntries(from: entries)
        #expect(result.count == RecentVaultsMenu.defaultLimit)
        #expect(result.first?.name == "N19")
        #expect(result.last?.name == "N10")
    }

    @Test("A custom limit caps the result")
    func capsToCustomLimit() {
        let entries = (0..<20).map { entry("N\($0)", "/Users/test/N\($0)", TimeInterval($0)) }
        #expect(RecentVaultsMenu.menuEntries(from: entries, limit: 3).count == 3)
    }

    @Test("A non-positive limit returns nothing")
    func nonPositiveLimitReturnsEmpty() {
        let entries = [entry("A", "/Users/test/A", 1)]
        #expect(RecentVaultsMenu.menuEntries(from: entries, limit: 0).isEmpty)
        #expect(RecentVaultsMenu.menuEntries(from: entries, limit: -5).isEmpty)
    }

    @Test("Empty input returns empty")
    func emptyInputReturnsEmpty() {
        #expect(RecentVaultsMenu.menuEntries(from: []).isEmpty)
    }

    @Test("Fewer entries than the limit returns them all, ordered")
    func fewerThanLimitReturnsAll() {
        let entries = [
            entry("A", "/Users/test/A", 1),
            entry("B", "/Users/test/B", 2),
        ]
        #expect(RecentVaultsMenu.menuEntries(from: entries).map(\.name) == ["B", "A"])
    }

    @Test("Identity is derived from the vault URL")
    func identityFromURL() {
        let e = entry("A", "/Users/test/A", 1)
        #expect(e.id == URL(fileURLWithPath: "/Users/test/A").absoluteString)
    }
}
