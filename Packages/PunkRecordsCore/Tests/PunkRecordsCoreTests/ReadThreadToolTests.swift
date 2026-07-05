import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("ReadThreadTool — get / search / semantic / list over saved threads")
struct ReadThreadToolTests {

    // MARK: - Test doubles

    /// In-memory ``ThreadStore`` for tool tests.
    actor MockThreadStore: ThreadStore {
        private var threads: [UUID: ChatThread] = [:]

        init(_ threads: [ChatThread] = []) {
            for thread in threads { self.threads[thread.id] = thread }
        }

        func summaries() async throws -> [ThreadSummary] { threads.values.map(\.summary) }
        func load(id: UUID) async throws -> ChatThread? { threads[id] }
        func save(_ thread: ChatThread) async throws { threads[thread.id] = thread }
        func delete(id: UUID) async throws { threads[id] = nil }
    }

    /// Returns a fixed query vector regardless of input (or `nil` to simulate an
    /// unavailable embedder).
    struct StubEmbedder: ThreadEmbedder {
        let queryVector: [Float]?
        func vector(for text: String) async -> [Float]? { queryVector }
    }

    /// Returns per-thread vectors from a fixed map.
    struct StubVectorSource: ThreadVectorSource {
        let vectors: [UUID: [Float]]
        func vector(forThreadID id: UUID, updatedAt: Date) async -> [Float]? { vectors[id] }
    }

    // MARK: - Fixtures

    private func thread(
        id: UUID = UUID(),
        title: String,
        user: String,
        assistant: String,
        updatedAt: Date
    ) -> ChatThread {
        ChatThread(
            id: id,
            title: title,
            updatedAt: updatedAt,
            messages: [
                ChatMessage(role: .user, content: user),
                ChatMessage(role: .assistant, content: assistant),
            ]
        )
    }

    // MARK: - Schema

    @Test("Exposes read_thread with a required mode enum")
    func schema() {
        let tool = ReadThreadTool(store: MockThreadStore())
        #expect(tool.name == "read_thread")
        #expect(tool.parameterSchema.required == ["mode"])
        if case let .property(_, _, enumValues, _)? = tool.parameterSchema.properties["mode"] {
            #expect(enumValues == ["get", "search", "semantic", "list"])
        } else {
            Issue.record("mode property missing enum values")
        }
    }

    // MARK: - get

    @Test("get returns a role-prefixed transcript of the requested thread")
    func getReturnsTranscript() async throws {
        let t = thread(title: "Reverb", user: "what is reverb?", assistant: "an echo", updatedAt: .init(timeIntervalSince1970: 1))
        let tool = ReadThreadTool(store: MockThreadStore([t]))
        let result = try await tool.execute(arguments: ["mode": "get", "thread_id": t.id.uuidString])
        #expect(!result.isError)
        #expect(result.content.contains("User: what is reverb?"))
        #expect(result.content.contains("Assistant: an echo"))
    }

    @Test("get with an unknown id is an error result")
    func getMissingIsError() async throws {
        let tool = ReadThreadTool(store: MockThreadStore())
        let result = try await tool.execute(arguments: ["mode": "get", "thread_id": UUID().uuidString])
        #expect(result.isError)
        #expect(result.content.contains("No conversation found"))
    }

    @Test("get with a malformed id is an error result")
    func getMalformedIDIsError() async throws {
        let tool = ReadThreadTool(store: MockThreadStore())
        let result = try await tool.execute(arguments: ["mode": "get", "thread_id": "not-a-uuid"])
        #expect(result.isError)
        #expect(result.content.contains("not a valid"))
    }

    @Test("get honors the transcript token budget by eliding an over-long thread")
    func getRespectsBudget() async throws {
        let filler = String(repeating: "alpha ", count: 80)
        let messages = (0..<8).map { i in
            ChatMessage(role: i % 2 == 0 ? .user : .assistant, content: "MSG\(i) \(filler)")
        }
        let t = ChatThread(title: "Long", updatedAt: .init(timeIntervalSince1970: 1), messages: messages)
        let tool = ReadThreadTool(store: MockThreadStore([t]), transcriptBudget: 200)
        let result = try await tool.execute(arguments: ["mode": "get", "thread_id": t.id.uuidString])
        #expect(result.content.contains("elided"))
        #expect(TokenEstimator.estimateTokens(in: result.content) <= 200)
    }

    // MARK: - list

    @Test("list returns recent conversations and excludes the active thread")
    func listExcludesActive() async throws {
        let active = thread(title: "Active", user: "hi", assistant: "hello", updatedAt: .init(timeIntervalSince1970: 100))
        let other = thread(title: "Older", user: "q", assistant: "a", updatedAt: .init(timeIntervalSince1970: 1))
        let tool = ReadThreadTool(store: MockThreadStore([active, other]), activeThreadID: active.id)
        let result = try await tool.execute(arguments: ["mode": "list"])
        #expect(!result.isError)
        #expect(result.content.contains("Older"))
        #expect(!result.content.contains(active.id.uuidString))
        #expect(result.content.contains(other.id.uuidString))
    }

    @Test("list with only the active thread reports none available")
    func listEmptyWhenOnlyActive() async throws {
        let active = thread(title: "Active", user: "hi", assistant: "hello", updatedAt: .init(timeIntervalSince1970: 1))
        let tool = ReadThreadTool(store: MockThreadStore([active]), activeThreadID: active.id)
        let result = try await tool.execute(arguments: ["mode": "list"])
        #expect(result.content.contains("No other saved conversations"))
    }

    @Test("list respects max_results")
    func listRespectsMaxResults() async throws {
        let threads = (0..<5).map { i in
            thread(title: "T\(i)", user: "u\(i)", assistant: "a\(i)", updatedAt: .init(timeIntervalSince1970: Double(i)))
        }
        let tool = ReadThreadTool(store: MockThreadStore(threads))
        let result = try await tool.execute(arguments: ["mode": "list", "max_results": 2])
        // Two rows → two "- [" bullet leads.
        let bullets = result.content.components(separatedBy: "- [").count - 1
        #expect(bullets == 2)
    }

    // MARK: - search (keyword)

    @Test("search keyword-ranks matches and excludes the active thread")
    func searchKeyword() async throws {
        let active = thread(
            title: "Guitar amps", user: "guitar tone", assistant: "use overdrive",
            updatedAt: .init(timeIntervalSince1970: 100)
        )
        let guitar = thread(
            title: "Guitar pedals", user: "distortion", assistant: "a guitar pedal for tone",
            updatedAt: .init(timeIntervalSince1970: 50)
        )
        let bread = thread(
            title: "Baking", user: "sourdough", assistant: "bread rises",
            updatedAt: .init(timeIntervalSince1970: 10)
        )
        let tool = ReadThreadTool(store: MockThreadStore([active, guitar, bread]), activeThreadID: active.id)

        let result = try await tool.execute(arguments: ["mode": "search", "query": "guitar"])
        #expect(!result.isError)
        #expect(result.content.contains(guitar.id.uuidString))
        #expect(!result.content.contains(bread.id.uuidString))
        // Active thread is excluded even though it matches the query.
        #expect(!result.content.contains(active.id.uuidString))
    }

    @Test("search with no matches reports so")
    func searchNoMatches() async throws {
        let t = thread(title: "Cooking", user: "pasta", assistant: "boil water", updatedAt: .init(timeIntervalSince1970: 1))
        let tool = ReadThreadTool(store: MockThreadStore([t]))
        let result = try await tool.execute(arguments: ["mode": "search", "query": "quantum"])
        #expect(result.content.contains("No conversations matched"))
    }

    @Test("search requires a non-empty query")
    func searchRequiresQuery() async throws {
        let tool = ReadThreadTool(store: MockThreadStore())
        let result = try await tool.execute(arguments: ["mode": "search", "query": "   "])
        #expect(result.isError)
    }

    // MARK: - semantic

    @Test("semantic ranks by cosine over cached vectors, dropping zero-similarity threads")
    func semanticRanks() async throws {
        let near = thread(title: "Near", user: "u1", assistant: "a1", updatedAt: .init(timeIntervalSince1970: 2))
        let far = thread(title: "Far", user: "u2", assistant: "a2", updatedAt: .init(timeIntervalSince1970: 1))
        let tool = ReadThreadTool(
            store: MockThreadStore([near, far]),
            embedder: StubEmbedder(queryVector: [1, 0]),
            vectors: StubVectorSource(vectors: [near.id: [1, 0], far.id: [0, 1]])
        )
        let result = try await tool.execute(arguments: ["mode": "semantic", "query": "anything"])
        #expect(!result.isError)
        #expect(result.content.contains(near.id.uuidString))
        // Orthogonal (cosine 0) thread is filtered out.
        #expect(!result.content.contains(far.id.uuidString))
    }

    @Test("semantic degrades to keyword when the embedder is unavailable")
    func semanticDegradesWhenEmbedderUnavailable() async throws {
        let guitar = thread(title: "Guitar", user: "guitar tone", assistant: "overdrive", updatedAt: .init(timeIntervalSince1970: 2))
        let tool = ReadThreadTool(
            store: MockThreadStore([guitar]),
            embedder: StubEmbedder(queryVector: nil),  // unavailable
            vectors: StubVectorSource(vectors: [:])
        )
        let result = try await tool.execute(arguments: ["mode": "semantic", "query": "guitar"])
        #expect(result.content.contains("Semantic search is unavailable"))
        // Fell back to a keyword match on the same query.
        #expect(result.content.contains(guitar.id.uuidString))
    }

    @Test("semantic degrades when no thread has a cached vector")
    func semanticDegradesWhenNoVectors() async throws {
        let guitar = thread(title: "Guitar", user: "guitar tone", assistant: "overdrive", updatedAt: .init(timeIntervalSince1970: 2))
        let tool = ReadThreadTool(
            store: MockThreadStore([guitar]),
            embedder: StubEmbedder(queryVector: [1, 0]),
            vectors: StubVectorSource(vectors: [:])  // nothing cached
        )
        let result = try await tool.execute(arguments: ["mode": "semantic", "query": "guitar"])
        #expect(result.content.contains("Semantic search is unavailable"))
    }

    // MARK: - Errors

    @Test("Missing or unknown mode is an error result")
    func badMode() async throws {
        let tool = ReadThreadTool(store: MockThreadStore())
        #expect(try await tool.execute(arguments: [:]).isError)
        #expect(try await tool.execute(arguments: ["mode": "wat"]).isError)
    }
}
