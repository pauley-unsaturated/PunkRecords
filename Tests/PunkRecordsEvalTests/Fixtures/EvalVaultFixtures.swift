import Foundation
import PunkRecordsCore
import PunkRecordsEvals

/// Shared fixture vaults and scenarios for eval tests.
enum EvalVaultFixtures {

    // MARK: - Document IDs

    static let concurrencyDocID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    static let reentrancyDocID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let graphDocID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let sendableDocID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let taskGroupDocID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let contradictDoc1ID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    static let contradictDoc2ID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    // MARK: - Documents

    static let concurrencyDoc = Document(
        id: concurrencyDocID,
        title: "Swift Concurrency Deep Dive",
        content: """
        # Swift Concurrency Deep Dive

        Swift's concurrency model is built on **structured concurrency** and the `async/await` pattern.

        ## Actors

        Actors provide *data-race safety* by isolating their mutable state.

        ## Task Groups

        Use `withTaskGroup` when you need to fan out work and collect results.

        See also [[Actor Reentrancy]] and [[Sendable Protocol]].
        """,
        path: "swift/concurrency-deep-dive.md",
        tags: ["swift", "concurrency", "async-await"],
        linkedDocumentIDs: [reentrancyDocID, sendableDocID]
    )

    static let reentrancyDoc = Document(
        id: reentrancyDocID,
        title: "Actor Reentrancy",
        content: """
        # Actor Reentrancy

        Actor reentrancy is a subtle issue in Swift concurrency. When an actor method hits a suspension
        point (`await`), other callers can execute on the actor in the meantime. Always re-check
        preconditions after suspension points.

        See [[Swift Concurrency Deep Dive]] for the broader concurrency model.
        """,
        path: "swift/actor-reentrancy.md",
        tags: ["swift", "concurrency"]
    )

    static let graphDoc = Document(
        id: graphDocID,
        title: "Graph Theory Basics",
        content: """
        # Graph Theory Basics

        A graph G = (V, E) consists of vertices and edges.

        ## Directed vs Undirected

        Wikilinks in a knowledge base are directed but we compute backlinks to make them bidirectional.
        """,
        path: "math/graph-theory-basics.md",
        tags: ["math", "graph-theory"]
    )

    static let sendableDoc = Document(
        id: sendableDocID,
        title: "Sendable Protocol",
        content: """
        # Sendable Protocol

        The Sendable protocol marks types that are safe to share across concurrency domains.
        Value types are implicitly Sendable. Reference types must be carefully audited.

        See [[Swift Concurrency Deep Dive]] and [[Actor Reentrancy]].
        """,
        path: "swift/sendable-protocol.md",
        tags: ["swift", "concurrency", "sendable"]
    )

    static let taskGroupDoc = Document(
        id: taskGroupDocID,
        title: "Task Groups in Practice",
        content: """
        # Task Groups in Practice

        Task groups provide structured fan-out. Use `withTaskGroup(of:returning:body:)` to spawn
        child tasks and collect results. Each child task inherits the parent's priority.

        See [[Swift Concurrency Deep Dive]].
        """,
        path: "swift/task-groups.md",
        tags: ["swift", "concurrency", "task-groups"]
    )

    static let contradictDoc1 = Document(
        id: contradictDoc1ID,
        title: "Actor Performance Notes",
        content: """
        # Actor Performance Notes

        Actors in Swift are extremely fast. The overhead of actor isolation is negligible —
        benchmarks show less than 1ns per hop. You should use actors everywhere.
        """,
        path: "swift/actor-performance-fast.md",
        tags: ["swift", "performance"]
    )

    static let contradictDoc2 = Document(
        id: contradictDoc2ID,
        title: "Actor Overhead Analysis",
        content: """
        # Actor Overhead Analysis

        Actors in Swift have significant overhead. The hop cost is ~50ns and under contention
        this can balloon to microseconds. Avoid actors in hot paths.
        """,
        path: "swift/actor-overhead-analysis.md",
        tags: ["swift", "performance"]
    )

    // MARK: - Standard 5-doc vault

    static let standardVault: [Document] = [
        concurrencyDoc, reentrancyDoc, graphDoc, sendableDoc, taskGroupDoc
    ]

    // MARK: - Search Results

    static let concurrencySearchResults: [SearchResult] = [
        SearchResult(documentID: concurrencyDocID, title: "Swift Concurrency Deep Dive",
                     path: "swift/concurrency-deep-dive.md",
                     excerpt: "Swift's concurrency model is built on structured concurrency and async/await.", score: 0.95),
        SearchResult(documentID: reentrancyDocID, title: "Actor Reentrancy",
                     path: "swift/actor-reentrancy.md",
                     excerpt: "Actor reentrancy is a subtle issue when hitting suspension points.", score: 0.82),
        SearchResult(documentID: sendableDocID, title: "Sendable Protocol",
                     path: "swift/sendable-protocol.md",
                     excerpt: "The Sendable protocol marks types safe to share across concurrency domains.", score: 0.75),
    ]

    static let graphSearchResults: [SearchResult] = [
        SearchResult(documentID: graphDocID, title: "Graph Theory Basics",
                     path: "math/graph-theory-basics.md",
                     excerpt: "A graph G = (V, E) consists of vertices and edges.", score: 0.90),
    ]

    static let actorPerformanceSearchResults: [SearchResult] = [
        SearchResult(documentID: contradictDoc1ID, title: "Actor Performance Notes",
                     path: "swift/actor-performance-fast.md",
                     excerpt: "Actors in Swift are extremely fast.", score: 0.88),
        SearchResult(documentID: contradictDoc2ID, title: "Actor Overhead Analysis",
                     path: "swift/actor-overhead-analysis.md",
                     excerpt: "Actors in Swift have significant overhead.", score: 0.85),
    ]
}
