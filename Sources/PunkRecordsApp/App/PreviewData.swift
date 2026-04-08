import Foundation
import PunkRecordsCore

/// Sample data for SwiftUI previews. Provides realistic documents and state
/// so we can iterate on views without needing a live vault.
enum PreviewData {

    /// URL to the bundled PreviewVault directory in app resources.
    static let previewVaultURL: URL = {
        Bundle.main.resourceURL!.appending(path: "PreviewVault")
    }()

    // MARK: - Documents

    static let markdownSample = """
    ---
    id: \(sampleDocumentID.uuidString)
    title: Swift Concurrency Deep Dive
    tags: [swift, concurrency, async-await]
    created: 2026-03-15
    modified: 2026-04-01
    ---

    # Swift Concurrency Deep Dive

    Swift's concurrency model is built on **structured concurrency** and the `async/await` pattern.
    This note covers the key concepts and how they fit together.

    ## Actors

    Actors provide *data-race safety* by isolating their mutable state. Only one task can execute
    on an actor at a time:

    ```swift
    actor BankAccount {
        private var balance: Double = 0

        func deposit(_ amount: Double) {
            balance += amount
        }

        func withdraw(_ amount: Double) throws -> Double {
            guard balance >= amount else {
                throw BankError.insufficientFunds
            }
            balance -= amount
            return amount
        }
    }
    ```

    ## Task Groups

    Use `withTaskGroup` when you need to fan out work and collect results:

    ```swift
    let results = await withTaskGroup(of: String.self) { group in
        for url in urls {
            group.addTask { await fetch(url) }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    ```

    ## Key Takeaways

    - [x] Understand `async/await` basics
    - [x] Learn about actor isolation
    - [ ] Explore `AsyncSequence` patterns
    - [ ] Study `Sendable` conformance rules

    > **Note:** See also [[Actor Reentrancy]] and [[Sendable Protocol]] for deeper dives.

    Related: [[Swift Language Notes]] | [[WWDC 2024 Sessions]]

    ---
    *Last reviewed: 2026-04-01*
    """

    static let shortNote = """
    # Quick Thoughts on Knowledge Graphs

    The idea of using **wikilinks** (`[[like this]]`) to build a personal knowledge graph
    is powerful. Each link creates a bidirectional relationship.

    See [[Graph Theory Basics]] for the underlying math.
    """

    static let emptyNote = """
    ---
    id: \(UUID().uuidString)
    title: Untitled
    tags: []
    ---

    # Untitled


    """

    // MARK: - Document IDs

    static let sampleDocumentID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    static let linkedDocID1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let linkedDocID2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let linkedDocID3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - Sample Documents

    static let sampleDocument = Document(
        id: sampleDocumentID,
        title: "Swift Concurrency Deep Dive",
        content: markdownSample,
        path: "swift/concurrency-deep-dive.md",
        tags: ["swift", "concurrency", "async-await"],
        created: Date(timeIntervalSince1970: 1_773_820_800), // 2026-03-15
        modified: Date(timeIntervalSince1970: 1_775_289_600), // 2026-04-01
        linkedDocumentIDs: [linkedDocID1, linkedDocID2]
    )

    static let quickNote = Document(
        id: linkedDocID1,
        title: "Quick Thoughts on Knowledge Graphs",
        content: shortNote,
        path: "quick-thoughts-kg.md",
        tags: ["knowledge-graph", "wikilinks"]
    )

    static let graphTheoryNote = Document(
        id: linkedDocID2,
        title: "Graph Theory Basics",
        content: "# Graph Theory Basics\n\nA graph G = (V, E) consists of vertices and edges...\n\nSee [[Swift Concurrency Deep Dive]] for practical applications.",
        path: "math/graph-theory-basics.md",
        tags: ["math", "graph-theory"]
    )

    static let actorReentrancyNote = Document(
        id: linkedDocID3,
        title: "Actor Reentrancy",
        content: "# Actor Reentrancy\n\nActor reentrancy is a subtle issue in Swift concurrency...",
        path: "swift/actor-reentrancy.md",
        tags: ["swift", "concurrency"]
    )

    static let allDocuments: [Document] = [
        sampleDocument,
        quickNote,
        graphTheoryNote,
        actorReentrancyNote,
    ]

    // MARK: - Search Results

    static let sampleSearchResults: [SearchResult] = [
        SearchResult(
            documentID: sampleDocumentID,
            title: "Swift Concurrency Deep Dive",
            excerpt: "Swift's concurrency model is built on structured concurrency and the async/await pattern.",
            score: 0.95,
            matchRanges: []
        ),
        SearchResult(
            documentID: linkedDocID3,
            title: "Actor Reentrancy",
            excerpt: "Actor reentrancy is a subtle issue in Swift concurrency...",
            score: 0.72,
            matchRanges: []
        ),
    ]

    // MARK: - Chat Messages

    static let sampleChatMessages: [ChatMessage] = [
        ChatMessage(role: .user, content: "What do my notes say about Swift concurrency?"),
        ChatMessage(role: .assistant, content: """
        Based on your knowledge base, here's what I found:

        Your **Swift Concurrency Deep Dive** note covers the key concepts:

        1. **Actors** — provide data-race safety through isolation
        2. **Task Groups** — fan-out pattern with `withTaskGroup`
        3. **Sendable** — protocol for cross-isolation-boundary safety

        You also have a related note on **Actor Reentrancy** that discusses subtle pitfalls.

        Your checklist shows you still want to explore `AsyncSequence` patterns and `Sendable` conformance rules. Want me to compile a note on either of those topics?
        """),
    ]

    // MARK: - Preview AppState

    @MainActor
    static func makePreviewAppState(withVault: Bool = true) -> AppState {
        let state = AppState()
        if withVault {
            state.currentVault = Vault(
                name: "Preview Vault",
                rootURL: previewVaultURL
            )
            state.selectedDocumentID = sampleDocumentID
        }
        return state
    }

    /// Creates an AppState with a live repository backed by the bundled PreviewVault.
    /// Use this for previews that need to actually load documents.
    @MainActor
    static func makePreviewAppStateWithRepo() -> AppState {
        let state = AppState()
        let url = previewVaultURL
        state.currentVault = Vault(name: "Preview Vault", rootURL: url)
        state.selectedDocumentID = sampleDocumentID
        state.configureForPreview(vaultRoot: url)
        return state
    }
}
