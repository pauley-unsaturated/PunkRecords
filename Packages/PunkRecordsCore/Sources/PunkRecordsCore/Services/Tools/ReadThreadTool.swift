import Foundation

/// Agent tool that lets the model reference the user's *other* saved
/// conversations mid-chat: fetch one by id, keyword-search across them, rank them
/// semantically by meaning, or list the most recent.
///
/// Backed by a ``ThreadStore`` plus optional embedding seams. The active
/// conversation (when its id is supplied at construction) is excluded from
/// `search`, `semantic`, and `list` so the model never cites the chat it is
/// already in. Semantic mode uses on-device embeddings via ``ThreadVectorSource``
/// and degrades to keyword results (with a note) when embeddings are unavailable.
public struct ReadThreadTool: AgentTool, Sendable {
    public let name = "read_thread"
    public let description = """
        Look up the user's OTHER saved chat conversations to recall earlier discussions. \
        Modes: "get" returns the full transcript of one conversation by thread_id; \
        "search" keyword-searches across conversations (returns id, title, and a snippet); \
        "semantic" searches by meaning using on-device embeddings; \
        "list" shows the most recent conversations. \
        The conversation you are currently in is never included in results.
        """

    private let store: any ThreadStore
    private let embedder: (any ThreadEmbedder)?
    private let vectors: (any ThreadVectorSource)?
    private let activeThreadID: UUID?

    /// Token budget for a full transcript returned by `get`.
    private let transcriptBudget: Int
    /// Token budget for the per-thread text built for keyword matching + snippets.
    private let perThreadTextBudget: Int
    /// Result cap when `max_results` is not supplied.
    private let defaultMaxResults: Int

    public var parameterSchema: ToolParameterSchema {
        ToolParameterSchema(
            properties: [
                "mode": ToolProperty(
                    type: "string",
                    description: "What to do: get, search, semantic, or list.",
                    enumValues: ["get", "search", "semantic", "list"]
                ),
                "thread_id": ToolProperty(
                    type: "string",
                    description: "Conversation id to fetch. Required for mode=get; ignored otherwise."
                ),
                "query": ToolProperty(
                    type: "string",
                    description: "Search text. Required for mode=search and mode=semantic."
                ),
                "max_results": ToolProperty(
                    type: "integer",
                    description: "Maximum number of results to return (optional)."
                ),
            ],
            required: ["mode"]
        )
    }

    public init(
        store: any ThreadStore,
        embedder: (any ThreadEmbedder)? = nil,
        vectors: (any ThreadVectorSource)? = nil,
        activeThreadID: UUID? = nil,
        transcriptBudget: Int = 1500,
        perThreadTextBudget: Int = 400,
        defaultMaxResults: Int = 5
    ) {
        self.store = store
        self.embedder = embedder
        self.vectors = vectors
        self.activeThreadID = activeThreadID
        self.transcriptBudget = transcriptBudget
        self.perThreadTextBudget = perThreadTextBudget
        self.defaultMaxResults = defaultMaxResults
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let modeRaw = arguments["mode"] as? String else {
            return ToolResult(
                content: "Missing required 'mode'. Use one of: get, search, semantic, list.",
                isError: true
            )
        }
        let limit = Self.parseMaxResults(arguments["max_results"]) ?? defaultMaxResults

        switch modeRaw.lowercased() {
        case "get":
            return try await runGet(arguments: arguments)
        case "search":
            return try await runSearch(arguments: arguments, limit: limit, semantic: false)
        case "semantic":
            return try await runSearch(arguments: arguments, limit: limit, semantic: true)
        case "list":
            return try await runList(limit: limit)
        default:
            return ToolResult(
                content: "Unknown mode '\(modeRaw)'. Use one of: get, search, semantic, list.",
                isError: true
            )
        }
    }

    // MARK: - Modes

    private func runGet(arguments: [String: Any]) async throws -> ToolResult {
        guard let idString = (arguments["thread_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !idString.isEmpty else {
            return ToolResult(
                content: "mode=get requires 'thread_id'. Use mode=list or mode=search to find one.",
                isError: true
            )
        }
        guard let id = UUID(uuidString: idString) else {
            return ToolResult(
                content: "'\(idString)' is not a valid conversation id. Copy an id from mode=list or mode=search.",
                isError: true
            )
        }
        guard let thread = try await store.load(id: id) else {
            return ToolResult(
                content: "No conversation found with id \(id.uuidString).",
                isError: true
            )
        }
        return ToolResult(content: ThreadTranscriptRenderer.render(thread, budget: transcriptBudget))
    }

    private func runList(limit: Int) async throws -> ToolResult {
        let summaries = try await candidateSummaries()
        guard !summaries.isEmpty else {
            return ToolResult(content: "No other saved conversations.")
        }
        let rows = summaries.prefix(limit)
            .map { formatRow($0, snippet: nil) }
            .joined(separator: "\n")
        return ToolResult(content: "Recent conversations:\n\(rows)")
    }

    private func runSearch(arguments: [String: Any], limit: Int, semantic: Bool) async throws -> ToolResult {
        guard let query = (arguments["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            let mode = semantic ? "semantic" : "search"
            return ToolResult(content: "mode=\(mode) requires a non-empty 'query'.", isError: true)
        }

        let summaries = try await candidateSummaries()
        guard !summaries.isEmpty else {
            return ToolResult(content: "No other saved conversations to search.")
        }

        // Load each candidate once: its rendered text backs both keyword matching
        // and result snippets.
        var texts: [UUID: String] = [:]
        for summary in summaries {
            if let thread = try await store.load(id: summary.id) {
                texts[summary.id] = ThreadTranscriptRenderer.render(thread, budget: perThreadTextBudget)
            }
        }

        if semantic {
            if let result = await runSemantic(query: query, summaries: summaries, texts: texts, limit: limit) {
                return result
            }
            // Embeddings unavailable — degrade to keyword, flagged in the output.
            let fallback = runKeyword(query: query, summaries: summaries, texts: texts, limit: limit)
            return ToolResult(content: """
                (Semantic search is unavailable on this device — showing keyword matches instead.)

                \(fallback)
                """)
        }

        return ToolResult(content: runKeyword(query: query, summaries: summaries, texts: texts, limit: limit))
    }

    // MARK: - Ranking helpers

    private func runKeyword(query: String, summaries: [ThreadSummary], texts: [UUID: String], limit: Int) -> String {
        let candidates = summaries.map { (summary: $0, text: texts[$0.id] ?? "") }
        let ranked = ThreadKeywordRanker.rank(query: query, candidates: candidates, limit: limit)
        guard !ranked.isEmpty else {
            return "No conversations matched '\(query)'."
        }
        let rows = ranked
            .map { formatRow($0.summary, snippet: snippet(from: texts[$0.summary.id])) }
            .joined(separator: "\n")
        return "Conversations matching '\(query)':\n\(rows)"
    }

    /// Semantic ranking. Returns `nil` to signal the caller should degrade to
    /// keyword (embedder/vectors missing, query un-embeddable, or no thread has a
    /// cached vector).
    private func runSemantic(query: String, summaries: [ThreadSummary], texts: [UUID: String], limit: Int) async -> ToolResult? {
        guard let embedder, let vectors else { return nil }
        guard let queryVector = await embedder.vector(for: query) else { return nil }

        var candidateVectors: [(id: UUID, vector: [Float])] = []
        for summary in summaries {
            if let vector = await vectors.vector(forThreadID: summary.id, updatedAt: summary.updatedAt) {
                candidateVectors.append((summary.id, vector))
            }
        }
        guard !candidateVectors.isEmpty else { return nil }

        let ranked = ThreadSemanticRanker
            .rank(query: queryVector, candidates: candidateVectors, limit: limit)
            .filter { $0.score > 0 }
        guard !ranked.isEmpty else {
            return ToolResult(content: "No conversations semantically matched '\(query)'.")
        }

        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = ranked.compactMap { scored -> String? in
            guard let summary = byID[scored.id] else { return nil }
            return formatRow(summary, snippet: snippet(from: texts[scored.id]))
        }.joined(separator: "\n")
        return ToolResult(content: "Conversations related to '\(query)':\n\(rows)")
    }

    // MARK: - Formatting

    private func candidateSummaries() async throws -> [ThreadSummary] {
        let all = try await store.summaries().filter { $0.id != activeThreadID }
        return ChatThreadHelpers.sortedSummaries(all)
    }

    private func formatRow(_ summary: ThreadSummary, snippet: String?) -> String {
        let plural = summary.messageCount == 1 ? "" : "s"
        var row = "- [\(summary.id.uuidString)] \(summary.title) (\(summary.messageCount) message\(plural))"
        if let snippet, !snippet.isEmpty {
            row += "\n  \(snippet)"
        }
        return row
    }

    private func snippet(from text: String?) -> String? {
        guard let text else { return nil }
        let line = ThreadTranscriptRenderer.singleLine(text, maxChars: 160)
        return line.isEmpty ? nil : line
    }

    static func parseMaxResults(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return max(1, intValue) }
        if let doubleValue = value as? Double { return max(1, Int(doubleValue)) }
        if let stringValue = value as? String, let parsed = Int(stringValue) { return max(1, parsed) }
        return nil
    }
}
