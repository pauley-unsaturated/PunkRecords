import Testing
import Foundation
import PunkRecordsCore
import PunkRecordsInfra
import PunkRecordsTestSupport

/// End-to-end coverage for the vault-wide search UI's data pipeline: a real
/// on-disk `SQLiteSearchIndex` (built in a `TempVaultFactory` vault) → the SAME
/// `SearchService.search` the agent's `vault_search` tool calls → the pure
/// `VaultSearchDisplay` mapping the UI renders. Locks in that the search box and
/// the agent resolve identical queries (free text, `tag:`, `title:`, combos) to
/// the identical notes.
@Suite("Vault Search Display Integration")
struct VaultSearchDisplayIntegrationTests {

    /// Same small corpus shape as `SQLiteSearchIndexTests.makeTaggedCorpus`, so
    /// the display pipeline is asserted against the exact index semantics the
    /// unit tests pin down.
    private static let corpus: [Document] = [
        Document(
            title: "Swift Concurrency Guide",
            content: "# Swift Concurrency\n\nActors, async/await and structured concurrency.",
            path: "swift-concurrency.md",
            tags: ["swift", "concurrency"]
        ),
        Document(
            title: "SwiftUI Layout",
            content: "# SwiftUI Layout\n\nStacks and geometry in SwiftUI.",
            path: "swiftui-layout.md",
            tags: ["swiftui", "ui"]
        ),
        Document(
            title: "Rust Ownership",
            content: "# Rust Ownership\n\nBorrow checker, lifetimes and concurrency.",
            path: "rust-ownership.md",
            tags: ["rust", "concurrency"]
        ),
    ]

    /// Builds an on-disk index inside a temp vault, seeded with `corpus`.
    private func makeIndexedVault() async throws -> (SQLiteSearchIndex, @Sendable () -> Void) {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault()
        let index = try SQLiteSearchIndex(vaultRoot: vault.rootURL)
        for doc in Self.corpus { try await index.index(document: doc) }
        return (index, cleanup)
    }

    /// Run a query through the UI's display pipeline and return the note paths.
    private func displayPaths(_ index: SQLiteSearchIndex, _ query: String) async throws -> [RelativePath] {
        let results = try await index.search(query: query)
        return VaultSearchDisplay.items(from: results).map(\.path)
    }

    // MARK: - Free text

    @Test("Free-text query maps to highlighted display items in index (BM25) order")
    func freeTextPipelinePreservesOrderAndHighlights() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }

        let raw = try await index.search(query: "concurrency")
        let items = VaultSearchDisplay.items(from: raw)

        // The display layer neither reorders nor drops hits — it renders exactly
        // what the shared SearchService returned, in the same order.
        #expect(items.map(\.path) == raw.map(\.path))
        #expect(!items.isEmpty)
        // At least one item shows a highlighted matched term from the snippet.
        #expect(items.contains { item in item.snippetSegments.contains { $0.isHighlighted } })
    }

    // MARK: - tag: / title: parity with SQLiteSearchIndex semantics

    @Test("tag: through the display pipeline returns exactly the tagged notes")
    func tagFilterPipeline() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let paths = try await displayPaths(index, "tag:concurrency")
        #expect(Set(paths) == ["swift-concurrency.md", "rust-ownership.md"])
    }

    @Test("tag: stays exact (swift ≠ swiftui) through the display pipeline")
    func tagFilterExactThroughPipeline() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let paths = try await displayPaths(index, "tag:swift")
        #expect(Set(paths) == ["swift-concurrency.md"])
    }

    @Test("title: substring filter through the display pipeline")
    func titleFilterPipeline() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let paths = try await displayPaths(index, "title:swift")
        #expect(Set(paths) == ["swift-concurrency.md", "swiftui-layout.md"])
    }

    @Test("Combined free-text + tag: narrows through the display pipeline")
    func combinedFreeTextAndTagPipeline() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let paths = try await displayPaths(index, "concurrency tag:swift")
        #expect(paths == ["swift-concurrency.md"])
    }

    @Test("A metadata-only hit (tag: with no free text) maps to a snippet-less item")
    func metadataOnlyHitHasNoSnippet() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let items = VaultSearchDisplay.items(from: try await index.search(query: "tag:swiftui"))
        #expect(items.map(\.path) == ["swiftui-layout.md"])
        #expect(items.allSatisfy { !$0.hasSnippet })
    }

    // MARK: - Agent ↔ UI parity

    @Test("The agent's vault_search tool and the search UI resolve a query to the same notes")
    func agentAndUIResolveSameNotes() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }

        // Combined tag: + title: — the exact metadata semantics both surfaces
        // must share (intersection of tag:concurrency and title:swift).
        let query = "tag:concurrency title:swift"

        // UI path: search → display model.
        let uiPaths = try await displayPaths(index, query)
        #expect(uiPaths == ["swift-concurrency.md"])

        // Agent path: the same SearchService, wrapped by the tool.
        let tool = VaultSearchTool(searchService: index)
        let toolResult = try await tool.execute(arguments: ["query": query])
        #expect(!toolResult.isError)
        // The tool formats titles; the UI keys off paths — both must surface the
        // one note the query resolves to, and neither the other corpus note.
        #expect(toolResult.content.contains("Swift Concurrency Guide"))
        #expect(!toolResult.content.contains("SwiftUI Layout"))
        #expect(!toolResult.content.contains("Rust Ownership"))
    }

    @Test("Empty query yields no results through the display pipeline")
    func emptyQueryYieldsNothing() async throws {
        let (index, cleanup) = try await makeIndexedVault()
        defer { cleanup() }
        let items = VaultSearchDisplay.items(from: try await index.search(query: "   "))
        #expect(items.isEmpty)
    }
}
