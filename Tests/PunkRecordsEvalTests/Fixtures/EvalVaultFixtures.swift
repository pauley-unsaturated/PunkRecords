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
    static let testingDocID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    static let meetingDocID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    static let deepWorkDocID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let sqliteFTSDocID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let indexingDocID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

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

    // MARK: - Cross-domain documents for diverse scenarios

    static let testingDoc = Document(
        id: testingDocID,
        title: "Swift Testing Strategies",
        content: """
        # Swift Testing Strategies

        A survey of how I approach testing in Swift projects.

        ## Unit vs Integration

        Unit tests cover single types in isolation, using mocks for dependencies.
        Integration tests exercise real I/O (file system, network) and confirm
        that components compose correctly.

        ## Swift Testing framework

        The new `Testing` framework replaces XCTest for new code. Key features:
        - `@Test` attribute instead of test class inheritance
        - `#expect` macros with structured failure output
        - Parallel execution by default
        - Tags via `.tags(.tagname)` for selective runs

        See also [[Swift Concurrency Deep Dive]] — async tests mean no more
        XCTestExpectation ceremony.
        """,
        path: "swift/testing-strategies.md",
        tags: ["swift", "testing"],
        linkedDocumentIDs: [concurrencyDocID]
    )

    static let meetingDoc = Document(
        id: meetingDocID,
        title: "Architecture Meeting 2026-04-10",
        content: """
        ---
        tags: [meeting, architecture]
        ---

        # Architecture Meeting — 2026-04-10

        Attendees: Mark, Sarah, Raj

        Decisions:
        - Migrate networking layer to Swift concurrency first (Sarah)
        - Audit actor reentrancy in BankAccount and ImageLoader (Raj)
        - Enable strict concurrency in CI (Mark)

        Open questions:
        - How to handle the SQLite layer's DispatchQueue-based isolation?
        - Should we use `withCheckedContinuation` or `withUnsafeContinuation`
          for legacy callback bridges?

        See [[Actor Reentrancy]] and [[Swift Concurrency Deep Dive]] for context.
        """,
        path: "meetings/2026-04-10-architecture.md",
        tags: ["meeting", "architecture"],
        linkedDocumentIDs: [reentrancyDocID, concurrencyDocID]
    )

    static let deepWorkDoc = Document(
        id: deepWorkDocID,
        title: "Deep Work Principles",
        content: """
        # Deep Work Principles

        Notes from Cal Newport's *Deep Work*.

        ## Core thesis

        The ability to focus without distraction on cognitively demanding tasks
        is becoming rare and valuable. Those who cultivate this skill will thrive.

        ## Four disciplines

        1. **Focus on the wildly important** — a small number of ambitious outcomes
        2. **Act on the lead measures** — inputs you control, not outputs
        3. **Keep a compelling scoreboard** — visible tracking drives behavior
        4. **Create a cadence of accountability** — regular review rhythm

        ## Application

        Block 90-minute focus sessions. No email, no Slack, phone in another room.
        Use [[Deep Work Principles]] in paired reviews with a colleague weekly.
        """,
        path: "reading/deep-work-principles.md",
        tags: ["reading", "productivity"]
    )

    static let sqliteFTSDoc = Document(
        id: sqliteFTSDocID,
        title: "SQLite FTS5 Overview",
        content: """
        # SQLite FTS5 Overview

        FTS5 is SQLite's full-text search module. It supports:
        - BM25 ranking (the default)
        - Phrase queries, prefix queries, NEAR queries
        - Custom tokenizers (porter, unicode61, trigram)

        ## Virtual table syntax

        ```sql
        CREATE VIRTUAL TABLE documents USING fts5(
            title, body, tags,
            tokenize = 'porter unicode61'
        );
        ```

        ## Snippet function

        `snippet(table, column_index, open, close, ellipsis, max_tokens)` returns
        highlighted excerpts suitable for search result display.

        See [[Indexing Strategies]] for when to pair FTS5 with other indexes.
        """,
        path: "databases/sqlite-fts5-overview.md",
        tags: ["database", "sqlite", "search"],
        linkedDocumentIDs: [indexingDocID]
    )

    static let indexingDoc = Document(
        id: indexingDocID,
        title: "Indexing Strategies",
        content: """
        # Indexing Strategies

        When to reach for which index type:

        - **B-tree** — default; good for equality and range queries on ordered columns
        - **FTS5** — full-text search; see [[SQLite FTS5 Overview]]
        - **Hash** — O(1) equality lookups, no range support
        - **Covering** — all queried columns in the index, avoids table lookups

        ## Trade-offs

        Every index speeds reads but slows writes. Benchmark before adding indexes
        to hot-write tables. Monitor index bloat on columns with high update churn.
        """,
        path: "databases/indexing-strategies.md",
        tags: ["database", "performance"],
        linkedDocumentIDs: [sqliteFTSDocID]
    )

    // MARK: - Standard 5-doc vault (legacy — used by existing tests)

    static let standardVault: [Document] = [
        concurrencyDoc, reentrancyDoc, graphDoc, sendableDoc, taskGroupDoc
    ]

    // MARK: - Diverse vault (12 docs across 4+ domains) for broad A/B testing

    static let diverseVault: [Document] = [
        concurrencyDoc, reentrancyDoc, sendableDoc, taskGroupDoc, testingDoc,
        graphDoc,
        contradictDoc1, contradictDoc2,
        meetingDoc, deepWorkDoc,
        sqliteFTSDoc, indexingDoc,
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

    // MARK: - Reusable live scenarios for variant A/B testing

    /// Simple Q&A with pre-loaded context — tests the system prompt's ability to
    /// answer from existing context without tool use.
    static let liveSimpleQAScenario = EvalScenario(
        id: "live-simple-qa",
        name: "Simple Q&A",
        description: "Answer from pre-loaded concurrency context",
        category: .simpleQA,
        vaultDocuments: standardVault,
        queryResultMap: ["concurrency": concurrencySearchResults,
                         "actor": concurrencySearchResults],
        userPrompt: "What do my notes say about actor reentrancy?",
        currentDocumentID: concurrencyDocID,
        scope: .document(concurrencyDocID),
        groundTruth: GroundTruth(
            turnRange: 1...3,
            requiredContent: ["reentrancy"],
            minToolCalls: 0
        )
    )

    /// Search + synthesize — tests tool use, especially vault_search + read_document flow.
    static let liveSearchSynthesizeScenario = EvalScenario(
        id: "live-search-synthesize",
        name: "Search + Synthesize",
        description: "Agent searches, reads, synthesizes",
        category: .vaultSearchSynthesize,
        vaultDocuments: standardVault,
        queryResultMap: [
            "graph": graphSearchResults,
            "graph theory": graphSearchResults,
        ],
        userPrompt: "Find everything I've written about graph theory and summarize it briefly.",
        groundTruth: GroundTruth(
            turnRange: 2...6,
            requiredContent: ["graph"],
            minToolCalls: 1
        )
    )

    /// Standard set of scenarios for variant A/B comparison.
    /// 2 scenarios × 2 variants = 4 live API calls per comparison run.
    static let liveScenarios: [EvalScenario] = [
        liveSimpleQAScenario,
        liveSearchSynthesizeScenario,
    ]

    // MARK: - Query result maps for the diverse vault

    /// Comprehensive query → results map covering queries the agent is likely to make
    /// across the 20 diverse scenarios.
    static let diverseQueryResults: [String: [SearchResult]] = [
        // Swift concurrency
        "concurrency": [
            SearchResult(documentID: concurrencyDocID, title: "Swift Concurrency Deep Dive",
                         path: "swift/concurrency-deep-dive.md",
                         excerpt: "Swift's concurrency model is built on structured concurrency and async/await.", score: 0.95),
            SearchResult(documentID: reentrancyDocID, title: "Actor Reentrancy",
                         path: "swift/actor-reentrancy.md",
                         excerpt: "Actor reentrancy is a subtle issue when hitting suspension points.", score: 0.82),
            SearchResult(documentID: sendableDocID, title: "Sendable Protocol",
                         path: "swift/sendable-protocol.md",
                         excerpt: "The Sendable protocol marks types safe to share across concurrency domains.", score: 0.75),
            SearchResult(documentID: taskGroupDocID, title: "Task Groups in Practice",
                         path: "swift/task-groups.md",
                         excerpt: "Task groups provide structured fan-out.", score: 0.72),
        ],
        "actor": [
            SearchResult(documentID: concurrencyDocID, title: "Swift Concurrency Deep Dive",
                         path: "swift/concurrency-deep-dive.md",
                         excerpt: "Actors provide data-race safety by isolating their mutable state.", score: 0.90),
            SearchResult(documentID: reentrancyDocID, title: "Actor Reentrancy",
                         path: "swift/actor-reentrancy.md",
                         excerpt: "Actor reentrancy is a subtle issue in Swift concurrency.", score: 0.88),
        ],
        "reentrancy": [
            SearchResult(documentID: reentrancyDocID, title: "Actor Reentrancy",
                         path: "swift/actor-reentrancy.md",
                         excerpt: "When an actor method hits a suspension point, other callers can execute.", score: 0.98),
        ],
        "sendable": [
            SearchResult(documentID: sendableDocID, title: "Sendable Protocol",
                         path: "swift/sendable-protocol.md",
                         excerpt: "The Sendable protocol marks types safe to share across concurrency domains.", score: 0.95),
        ],
        "task group": [
            SearchResult(documentID: taskGroupDocID, title: "Task Groups in Practice",
                         path: "swift/task-groups.md",
                         excerpt: "Task groups provide structured fan-out via withTaskGroup.", score: 0.95),
        ],
        "testing": [
            SearchResult(documentID: testingDocID, title: "Swift Testing Strategies",
                         path: "swift/testing-strategies.md",
                         excerpt: "Unit vs integration; Swift Testing framework replaces XCTest.", score: 0.92),
        ],
        "actor performance": actorPerformanceSearchResults,
        "performance": actorPerformanceSearchResults,

        // Math
        "graph": graphSearchResults,
        "graph theory": graphSearchResults,

        // Meeting / productivity
        "meeting": [
            SearchResult(documentID: meetingDocID, title: "Architecture Meeting 2026-04-10",
                         path: "meetings/2026-04-10-architecture.md",
                         excerpt: "Decisions: migrate networking, audit reentrancy, enable strict concurrency.", score: 0.93),
        ],
        "architecture": [
            SearchResult(documentID: meetingDocID, title: "Architecture Meeting 2026-04-10",
                         path: "meetings/2026-04-10-architecture.md",
                         excerpt: "Architecture review. Networking migration, actor audit, CI changes.", score: 0.90),
        ],
        "deep work": [
            SearchResult(documentID: deepWorkDocID, title: "Deep Work Principles",
                         path: "reading/deep-work-principles.md",
                         excerpt: "The ability to focus without distraction is becoming rare and valuable.", score: 0.96),
        ],
        "productivity": [
            SearchResult(documentID: deepWorkDocID, title: "Deep Work Principles",
                         path: "reading/deep-work-principles.md",
                         excerpt: "Four disciplines: focus, lead measures, scoreboard, accountability.", score: 0.88),
        ],

        // Databases
        "database": [
            SearchResult(documentID: sqliteFTSDocID, title: "SQLite FTS5 Overview",
                         path: "databases/sqlite-fts5-overview.md",
                         excerpt: "FTS5 is SQLite's full-text search module.", score: 0.91),
            SearchResult(documentID: indexingDocID, title: "Indexing Strategies",
                         path: "databases/indexing-strategies.md",
                         excerpt: "B-tree, FTS5, hash, covering indexes — trade-offs.", score: 0.87),
        ],
        "sqlite": [
            SearchResult(documentID: sqliteFTSDocID, title: "SQLite FTS5 Overview",
                         path: "databases/sqlite-fts5-overview.md",
                         excerpt: "FTS5 with BM25 ranking, phrase queries, custom tokenizers.", score: 0.95),
        ],
        "fts": [
            SearchResult(documentID: sqliteFTSDocID, title: "SQLite FTS5 Overview",
                         path: "databases/sqlite-fts5-overview.md",
                         excerpt: "FTS5 is SQLite's full-text search module with BM25 ranking.", score: 0.98),
        ],
        "indexing": [
            SearchResult(documentID: indexingDocID, title: "Indexing Strategies",
                         path: "databases/indexing-strategies.md",
                         excerpt: "B-tree vs FTS5 vs hash vs covering; trade-offs for reads vs writes.", score: 0.96),
        ],
    ]

    static let diverseBacklinks: [DocumentID: [DocumentID]] = [
        concurrencyDocID: [reentrancyDocID, sendableDocID, testingDocID, meetingDocID],
        reentrancyDocID: [concurrencyDocID, meetingDocID],
        sendableDocID: [concurrencyDocID],
        sqliteFTSDocID: [indexingDocID],
        indexingDocID: [sqliteFTSDocID],
    ]

    // MARK: - The 20 diverse scenarios

    // CATEGORY 1 — Simple Q&A, no tools required (context pre-loaded)
    //
    // Ground truth philosophy: content keywords drive pass/fail. Turn ranges are
    // generous upper bounds to avoid punishing a model that hedges or verifies.
    // Tool use is optional — the agent can legitimately answer from pre-loaded context.

    static let s01_qaActorReentrancy = EvalScenario(
        id: "qa-actor-reentrancy",
        name: "Q&A: Actor Reentrancy",
        description: "Answer directly from pre-loaded concurrency context",
        category: .simpleQA,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "What do my notes say about actor reentrancy?",
        currentDocumentID: concurrencyDocID,
        scope: .document(concurrencyDocID),
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["reentrancy"])
    )

    static let s02_qaSendableBrief = EvalScenario(
        id: "qa-sendable-brief",
        name: "Q&A: Sendable (brief)",
        description: "Short definition-style answer",
        category: .simpleQA,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "Briefly: what is the Sendable protocol?",
        currentDocumentID: sendableDocID,
        scope: .document(sendableDocID),
        groundTruth: GroundTruth(turnRange: 1...4, requiredContent: ["sendable"])
    )

    static let s03_qaTaskGroups = EvalScenario(
        id: "qa-task-groups",
        name: "Q&A: Task Groups",
        description: "Relate a concept to the broader model",
        category: .simpleQA,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "How do task groups fit into structured concurrency?",
        currentDocumentID: taskGroupDocID,
        scope: .document(taskGroupDocID),
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["task group"])
    )

    static let s04_qaDeepWork = EvalScenario(
        id: "qa-deep-work",
        name: "Q&A: Deep Work thesis",
        description: "Summarize main thesis of a reading note",
        category: .simpleQA,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "What's the main thesis of my Deep Work notes?",
        currentDocumentID: deepWorkDocID,
        scope: .document(deepWorkDocID),
        groundTruth: GroundTruth(turnRange: 1...4, requiredContent: ["focus"])
    )

    // CATEGORY 2 — Search (tool use typical but not required)

    static let s05_searchGraph = EvalScenario(
        id: "search-graph-theory",
        name: "Search: graph theory",
        description: "Find and summarize single-domain notes",
        category: .vaultSearchSynthesize,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Find my notes on graph theory and summarize them briefly.",
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["graph"])
    )

    static let s06_searchDatabase = EvalScenario(
        id: "search-database",
        name: "Search: databases",
        description: "Multi-hit search across database notes",
        category: .vaultSearchSynthesize,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "What have I written about databases?",
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["database", "index"])
    )

    static let s07_searchQuantum = EvalScenario(
        id: "search-quantum",
        name: "Search: no matches",
        description: "Graceful handling of empty search results",
        category: .vaultSearchSynthesize,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Do I have any notes on quantum computing?",
        groundTruth: GroundTruth(turnRange: 1...5, forbiddenContent: ["error", "crash"])
    )

    // CATEGORY 3 — Multi-step research (search + read + synthesize typical)

    static let s08_researchConcurrency = EvalScenario(
        id: "research-concurrency-overview",
        name: "Research: concurrency overview",
        description: "Aggregate coverage across multiple notes",
        category: .multiStepResearch,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "Give me a comprehensive overview of my Swift concurrency knowledge.",
        groundTruth: GroundTruth(turnRange: 1...10, requiredContent: ["actor", "concurrency"])
    )

    static let s09_researchFTS = EvalScenario(
        id: "research-fts",
        name: "Research: FTS5 details",
        description: "Deep-dive into a technical topic via read",
        category: .multiStepResearch,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "How does FTS5 work according to my notes? Include specific details.",
        groundTruth: GroundTruth(turnRange: 1...8, requiredContent: ["bm25", "tokeniz"])
    )

    static let s10_researchCrossDomain = EvalScenario(
        id: "research-cross-domain",
        name: "Research: cross-domain connection",
        description: "Connect two topics from different domains",
        category: .multiStepResearch,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "How does my note on Swift testing connect to my concurrency notes?",
        groundTruth: GroundTruth(turnRange: 1...10, requiredContent: ["testing", "concurrency"])
    )

    static let s11_researchActorPerf = EvalScenario(
        id: "research-actor-performance",
        name: "Research: actor performance (contradictions)",
        description: "Finds and surfaces contradicting notes",
        category: .edgeCaseContradiction,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "What do my notes say about actor performance in Swift?",
        groundTruth: GroundTruth(turnRange: 1...8, requiredContent: ["contradict", "overhead"])
    )

    // CATEGORY 4 — Note creation
    // These keep minToolCalls because the agent MUST call create_note to satisfy the task.

    static let s12_createSynthesis = EvalScenario(
        id: "create-synthesis",
        name: "Create: concurrency synthesis",
        description: "Create a note linking multiple existing notes",
        category: .noteCreation,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        backlinkMap: diverseBacklinks,
        userPrompt: "Create a synthesis note that links my existing Swift concurrency notes together.",
        groundTruth: GroundTruth(turnRange: 1...10, minToolCalls: 1)
    )

    static let s13_createNewTopic = EvalScenario(
        id: "create-new-topic",
        name: "Create: new topic (no search)",
        description: "Create from scratch without searching",
        category: .noteCreation,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Create a brief note about Dijkstra's shortest-path algorithm.",
        groundTruth: GroundTruth(turnRange: 1...6, minToolCalls: 1)
    )

    static let s14_createFromMeeting = EvalScenario(
        id: "create-from-meeting",
        name: "Create: action items from meeting",
        description: "Read meeting notes, extract action items, create note",
        category: .noteCreation,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Read my latest architecture meeting notes and create a separate action-items note.",
        groundTruth: GroundTruth(turnRange: 1...8, minToolCalls: 1)
    )

    // CATEGORY 5 — Critique / analysis (tools optional — agent may answer from context)

    static let s15_critiqueGraphGaps = EvalScenario(
        id: "critique-graph-gaps",
        name: "Critique: graph theory gaps",
        description: "Identify what's missing on a topic",
        category: .multiStepResearch,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "What's missing from my notes on graph theory? What should I add?",
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["graph"])
    )

    static let s16_critiqueContradictions = EvalScenario(
        id: "critique-contradictions",
        name: "Critique: find contradictions",
        description: "Explicitly surface contradictory notes",
        category: .edgeCaseContradiction,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Are there any contradictions in my notes about actor performance?",
        groundTruth: GroundTruth(turnRange: 1...8, requiredContent: ["contradict"])
    )

    static let s17_critiqueCoverage = EvalScenario(
        id: "critique-coverage",
        name: "Critique: coverage analysis",
        description: "Evaluate thoroughness of a topic",
        category: .multiStepResearch,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "How thorough is my coverage of Swift concurrency? What areas are well-covered and what's thin?",
        groundTruth: GroundTruth(turnRange: 1...8, requiredContent: ["concurrency"])
    )

    // CATEGORY 6 — Edge cases

    static let s18_edgeEmptyVault = EvalScenario(
        id: "edge-empty-vault",
        name: "Edge: empty vault",
        description: "Vault with zero documents",
        category: .edgeCaseEmpty,
        vaultDocuments: [],
        userPrompt: "What do my notes say about REST APIs?",
        groundTruth: GroundTruth(turnRange: 1...6, forbiddenContent: ["error occurred", "crashed"])
    )

    static let s19_edgeAmbiguous = EvalScenario(
        id: "edge-ambiguous",
        name: "Edge: ambiguous query",
        description: "Single-word query with no context — agent must interpret",
        category: .simpleQA,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "Tell me about concurrency.",
        groundTruth: GroundTruth(turnRange: 1...8, requiredContent: ["concurrency"])
    )

    static let s20_edgeSpecificPhrase = EvalScenario(
        id: "edge-specific-phrase",
        name: "Edge: specific multi-word phrase",
        description: "Query requires precise search matching",
        category: .vaultSearchSynthesize,
        vaultDocuments: diverseVault,
        queryResultMap: diverseQueryResults,
        userPrompt: "I want to use `withTaskGroup` — do my notes discuss this?",
        groundTruth: GroundTruth(turnRange: 1...6, requiredContent: ["task group"])
    )

    // MARK: - Collected scenario sets

    /// Full 20-scenario diverse set for broad variant A/B comparison.
    /// Cost: ~$0.30-0.60 per variant run (Sonnet 4.6, real API).
    static let diverseScenarios: [EvalScenario] = [
        s01_qaActorReentrancy, s02_qaSendableBrief, s03_qaTaskGroups, s04_qaDeepWork,
        s05_searchGraph, s06_searchDatabase, s07_searchQuantum,
        s08_researchConcurrency, s09_researchFTS, s10_researchCrossDomain, s11_researchActorPerf,
        s12_createSynthesis, s13_createNewTopic, s14_createFromMeeting,
        s15_critiqueGraphGaps, s16_critiqueContradictions, s17_critiqueCoverage,
        s18_edgeEmptyVault, s19_edgeAmbiguous, s20_edgeSpecificPhrase,
    ]
}
