import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("ChatThread model + helpers")
struct ChatThreadTests {

    // MARK: - Title derivation

    @Test("Title comes from the first user message, whitespace collapsed")
    func titleFromFirstUserMessage() {
        let messages = [
            ChatMessage(role: .assistant, content: "hello, how can I help?"),
            ChatMessage(role: .user, content: "  What   is\n\n in my   vault? "),
            ChatMessage(role: .user, content: "second question"),
        ]
        #expect(ChatThreadHelpers.deriveTitle(from: messages) == "What is in my vault?")
    }

    @Test("Empty / whitespace-only first user message falls back to the default title")
    func titleFallsBackToDefault() {
        #expect(ChatThreadHelpers.deriveTitle(fromFirstUserMessage: "   \n  ") == ChatThreadHelpers.defaultTitle)
        #expect(ChatThreadHelpers.deriveTitle(from: []) == ChatThreadHelpers.defaultTitle)
        // No user message at all (assistant-only) also falls back.
        #expect(ChatThreadHelpers.deriveTitle(from: [ChatMessage(role: .assistant, content: "hi")])
            == ChatThreadHelpers.defaultTitle)
    }

    @Test("Long titles are truncated with an ellipsis at the max length")
    func titleTruncates() {
        let long = String(repeating: "a", count: ChatThreadHelpers.maxTitleLength + 20)
        let title = ChatThreadHelpers.deriveTitle(fromFirstUserMessage: long)
        #expect(title.hasSuffix("…"))
        // Body (sans ellipsis) is clamped to the max length.
        #expect(title.dropLast().count == ChatThreadHelpers.maxTitleLength)
    }

    @Test("A title exactly at the limit is not truncated")
    func titleAtLimitNotTruncated() {
        let exact = String(repeating: "b", count: ChatThreadHelpers.maxTitleLength)
        let title = ChatThreadHelpers.deriveTitle(fromFirstUserMessage: exact)
        #expect(title == exact)
        #expect(!title.hasSuffix("…"))
    }

    // MARK: - Summary sorting

    @Test("Summaries sort by updatedAt descending, id-tiebroken")
    func summariesSortNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        let older = ThreadSummary(id: UUID(), title: "older", updatedAt: base, messageCount: 1)
        let newer = ThreadSummary(id: UUID(), title: "newer", updatedAt: base.addingTimeInterval(60), messageCount: 2)
        let sorted = ChatThreadHelpers.sortedSummaries([older, newer])
        #expect(sorted.map(\.title) == ["newer", "older"])
    }

    @Test("Equal timestamps break ties deterministically by id")
    func summariesTieBreakDeterministic() {
        let ts = Date(timeIntervalSince1970: 5_000)
        let a = ThreadSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "a", updatedAt: ts, messageCount: 0)
        let b = ThreadSummary(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!, title: "b", updatedAt: ts, messageCount: 0)
        // Same input in either order yields the same ordering.
        #expect(ChatThreadHelpers.sortedSummaries([a, b]) == ChatThreadHelpers.sortedSummaries([b, a]))
    }

    // MARK: - Migration decision

    @Test("Migrate only when legacy content exists and no threads do")
    func migrationDecisionMatrix() {
        #expect(ChatThreadHelpers.shouldMigrateLegacyTranscript(hasLegacyContent: true, hasExistingThreads: false))
        #expect(!ChatThreadHelpers.shouldMigrateLegacyTranscript(hasLegacyContent: true, hasExistingThreads: true))
        #expect(!ChatThreadHelpers.shouldMigrateLegacyTranscript(hasLegacyContent: false, hasExistingThreads: false))
        #expect(!ChatThreadHelpers.shouldMigrateLegacyTranscript(hasLegacyContent: false, hasExistingThreads: true))
    }

    // MARK: - Forking

    /// A four-message source conversation with stable message ids for slicing.
    private func forkSource() -> ChatThread {
        ChatThread(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            title: "What is in my vault?",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            messages: [
                ChatMessage(role: .user, content: "What is in my vault?"),
                ChatMessage(role: .assistant, content: "Notes about DSP."),
                ChatMessage(role: .user, content: "Tell me more about filters."),
                ChatMessage(role: .assistant, content: "Filters shape frequency content."),
            ]
        )
    }

    @Test("Fork slices messages up to and including the target, with lineage")
    func forkSlicesAndCarriesLineage() {
        let source = forkSource()
        let target = source.messages[1] // first assistant reply
        let now = Date(timeIntervalSince1970: 9_999)
        let newID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

        let forked = try! #require(ChatThreadHelpers.fork(source, atMessageID: target.id, newThreadID: newID, now: now))

        // Slice is [0...1] — up to AND including the target.
        #expect(forked.messages.map(\.id) == [source.messages[0].id, source.messages[1].id])
        // Fresh identity + injected clock.
        #expect(forked.id == newID)
        #expect(forked.id != source.id)
        #expect(forked.createdAt == now)
        #expect(forked.updatedAt == now)
        // Lineage points back at the source and the branch point.
        #expect(forked.parentThreadID == source.id)
        #expect(forked.forkedAtMessageID == target.id)
        #expect(forked.schemaVersion == ChatThread.currentSchemaVersion)
    }

    @Test("Forking at the last message is a full copy with lineage")
    func forkAtLastMessageIsFullCopy() {
        let source = forkSource()
        let last = source.messages[source.messages.count - 1]
        let forked = try! #require(ChatThreadHelpers.fork(source, atMessageID: last.id))
        #expect(forked.messages.map(\.id) == source.messages.map(\.id))
        #expect(forked.parentThreadID == source.id)
        #expect(forked.forkedAtMessageID == last.id)
    }

    @Test("Forking at the first message yields a single-message thread")
    func forkAtFirstMessage() {
        let source = forkSource()
        let first = source.messages[0]
        let forked = try! #require(ChatThreadHelpers.fork(source, atMessageID: first.id))
        #expect(forked.messages.map(\.id) == [first.id])
        #expect(forked.forkedAtMessageID == first.id)
    }

    @Test("Forking at a message id not in the thread returns nil")
    func forkNotFoundReturnsNil() {
        let source = forkSource()
        #expect(ChatThreadHelpers.fork(source, atMessageID: UUID()) == nil)
    }

    @Test("Fork title is derived from the sliced messages")
    func forkTitleFromSlice() {
        let source = forkSource()
        let forked = try! #require(ChatThreadHelpers.fork(source, atMessageID: source.messages[1].id))
        // First user message is unchanged by the slice, so the title matches the
        // source's — an acceptable overlap; lineage carries the distinction.
        #expect(forked.title == ChatThreadHelpers.deriveTitle(from: Array(source.messages[0...1])))
        #expect(forked.title == "What is in my vault?")
    }

    @Test("Forking leaves the source thread untouched")
    func forkLeavesSourceUnchanged() {
        let source = forkSource()
        let before = source
        _ = ChatThreadHelpers.fork(source, atMessageID: source.messages[1].id)
        #expect(source == before)
        #expect(source.parentThreadID == nil)
        #expect(source.messages.count == 4)
    }

    // MARK: - Codable round-trips

    /// Round-trip a thread whose messages carry a populated `MessageContext` and
    /// a tool-call chip, asserting field-level equality survives encode→decode —
    /// so a reloaded thread faithfully knows which note each turn was about.
    @Test("ChatThread round-trips messages with context and a tool call losslessly")
    func chatThreadCodableRoundTrip() throws {
        let noteID = UUID()
        let context = MessageContext(
            scope: .document(noteID),
            scopeLabel: "Document",
            currentDocumentID: noteID,
            selection: "a selected phrase",
            variantID: "terse-v1",
            userPrompt: "explain this"
        )
        let userMessage = ChatMessage(
            role: .user,
            content: "explain this",
            attachments: [
                ChatAttachmentMetadata(bookmarkBase64: "Ym9va21hcms=", filename: "a.txt", byteCount: 12, type: .text)
            ],
            attachmentTranscript: "<!-- attachment note -->",
            context: context,
            providerID: .anthropic
        )
        let toolMessage = ChatMessage(
            role: .tool,
            content: "",
            toolCall: ToolCallInfo(name: "vault_search", arguments: "{\"q\":\"x\"}", output: "3 hits", isError: false, isInFlight: false)
        )
        let assistantMessage = ChatMessage(role: .assistant, content: "here you go", context: context, providerID: .anthropic)

        let thread = ChatThread(
            title: "explain this",
            parentThreadID: UUID(),
            forkedAtMessageID: userMessage.id,
            messages: [userMessage, toolMessage, assistantMessage]
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: data)

        #expect(decoded == thread)
        // Spot-check the load-bearing fields explicitly.
        #expect(decoded.forkedAtMessageID == userMessage.id)
        #expect(decoded.parentThreadID == thread.parentThreadID)
        #expect(decoded.messages[0].context == context)
        #expect(decoded.messages[0].id == userMessage.id)
        #expect(decoded.messages[0].timestamp == userMessage.timestamp)
        #expect(decoded.messages[1].toolCall == toolMessage.toolCall)
        #expect(decoded.messages[2].context?.currentDocumentID == noteID)
    }

    @Test("schemaVersion defaults to the current version and survives round-trip")
    func schemaVersionRoundTrips() throws {
        let thread = ChatThread(messages: [ChatMessage(role: .user, content: "hi")])
        #expect(thread.schemaVersion == ChatThread.currentSchemaVersion)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))
        #expect(decoded.schemaVersion == ChatThread.currentSchemaVersion)
    }

    @Test("A thread JSON missing schemaVersion decodes leniently to v1")
    func schemaVersionLenientDecode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "legacy",
          "createdAt": 0,
          "updatedAt": 0,
          "messages": []
        }
        """
        let decoded = try JSONDecoder().decode(ChatThread.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.id == id)
        #expect(decoded.title == "legacy")
        #expect(decoded.messages.isEmpty)
    }

    @Test("update() replaces messages, re-derives the title, and bumps updatedAt")
    func updateRefreshesTitleAndTimestamp() {
        var thread = ChatThread()
        let before = thread.updatedAt
        thread.update(
            messages: [ChatMessage(role: .user, content: "a brand new question")],
            now: before.addingTimeInterval(10)
        )
        #expect(thread.title == "a brand new question")
        #expect(thread.updatedAt == before.addingTimeInterval(10))
        #expect(thread.summary.messageCount == 1)
    }

    // MARK: - Focus note (schema + projection)

    @Test("update() stores the focus note, and it projects into the summary")
    func updateStoresFocusNote() {
        var thread = ChatThread()
        let focus = ThreadFocusNote(title: "DSP Filters", path: "dsp/filters.md")
        thread.update(messages: [ChatMessage(role: .user, content: "about filters")], focusNote: focus)
        #expect(thread.focusNote == focus)
        #expect(thread.summary.focusNote == focus)
    }

    @Test("ChatThread round-trips its focus note through Codable")
    func chatThreadFocusNoteRoundTrip() throws {
        var thread = ChatThread(messages: [ChatMessage(role: .user, content: "hi")])
        thread.update(
            messages: thread.messages,
            focusNote: ThreadFocusNote(title: "Actor Reentrancy", path: "swift/actor.md")
        )
        let decoded = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))
        #expect(decoded == thread)
        #expect(decoded.focusNote == ThreadFocusNote(title: "Actor Reentrancy", path: "swift/actor.md"))
    }

    @Test("A thread JSON without a focusNote key decodes leniently to nil")
    func chatThreadFocusNoteLenientDecode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "legacy",
          "createdAt": 0,
          "updatedAt": 0,
          "messages": []
        }
        """
        let decoded = try JSONDecoder().decode(ChatThread.self, from: Data(json.utf8))
        #expect(decoded.focusNote == nil)
        #expect(decoded.summary.focusNote == nil)
    }

    // MARK: - ThreadSummary lenient decode

    @Test("ThreadSummary decodes with the new parentThreadID / focusNote fields present")
    func threadSummaryDecodesWithNewFields() throws {
        let id = UUID()
        let parent = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "child",
          "updatedAt": 12,
          "messageCount": 3,
          "parentThreadID": "\(parent.uuidString)",
          "focusNote": { "title": "Note X", "path": "x.md" }
        }
        """
        let decoded = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        #expect(decoded.parentThreadID == parent)
        #expect(decoded.hasParent)
        #expect(decoded.focusNote == ThreadFocusNote(title: "Note X", path: "x.md"))
    }

    @Test("ThreadSummary decodes leniently when parentThreadID / focusNote are absent")
    func threadSummaryDecodesWithoutNewFields() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "root",
          "updatedAt": 7,
          "messageCount": 1
        }
        """
        let decoded = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        #expect(decoded.parentThreadID == nil)
        #expect(!decoded.hasParent)
        #expect(decoded.focusNote == nil)
    }

    // MARK: - Thread tree assembly

    private func summaryRow(
        _ id: UUID,
        parent: UUID? = nil,
        updated: TimeInterval,
        title: String = "t"
    ) -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            updatedAt: Date(timeIntervalSince1970: updated),
            messageCount: 1,
            parentThreadID: parent
        )
    }

    @Test("Thread tree nests forked children under their parent")
    func threadTreeNests() {
        let parentID = UUID()
        let childID = UUID()
        let parent = summaryRow(parentID, updated: 100, title: "parent")
        let child = summaryRow(childID, parent: parentID, updated: 200, title: "child")
        // Input order shouldn't matter — child listed first.
        let tree = ChatThreadHelpers.threadTree(from: [child, parent])
        #expect(tree.count == 1)
        #expect(tree[0].summary.id == parentID)
        #expect(tree[0].children.map(\.summary.id) == [childID])
        #expect(tree[0].children[0].children.isEmpty)
    }

    @Test("An orphaned parent reference surfaces the child as a flat top-level row")
    func threadTreeOrphan() {
        let childID = UUID()
        let child = summaryRow(childID, parent: UUID(), updated: 100) // parent not in the set
        let tree = ChatThreadHelpers.threadTree(from: [child])
        #expect(tree.map(\.summary.id) == [childID])
        #expect(tree[0].children.isEmpty)
    }

    @Test("A self-parent thread is a flat top-level row, not its own child")
    func threadTreeSelfParent() {
        let id = UUID()
        let selfParented = summaryRow(id, parent: id, updated: 100)
        let tree = ChatThreadHelpers.threadTree(from: [selfParented])
        #expect(tree.map(\.summary.id) == [id])
        #expect(tree[0].children.isEmpty)
    }

    @Test("Thread tree sorts newest-first within each level")
    func threadTreeSortsNewestFirstPerLevel() {
        let parentID = UUID()
        let parent = summaryRow(parentID, updated: 50, title: "p")
        let older = summaryRow(UUID(), parent: parentID, updated: 100, title: "older")
        let newer = summaryRow(UUID(), parent: parentID, updated: 300, title: "newer")
        let rootB = summaryRow(UUID(), updated: 500, title: "rootB")
        let tree = ChatThreadHelpers.threadTree(from: [parent, older, newer, rootB])
        // Roots newest-first: rootB (500) before p (50).
        #expect(tree.map(\.summary.title) == ["rootB", "p"])
        // Children newest-first.
        #expect(tree[1].children.map(\.summary.title) == ["newer", "older"])
    }

    @Test("Thread tree surfaces every summary exactly once even under a pure cycle")
    func threadTreeCycleSafe() {
        let a = UUID()
        let b = UUID()
        let sa = summaryRow(a, parent: b, updated: 100, title: "a")
        let sb = summaryRow(b, parent: a, updated: 200, title: "b")
        let tree = ChatThreadHelpers.threadTree(from: [sa, sb])

        var ids: [UUID] = []
        func walk(_ nodes: [ChatThreadHelpers.ThreadTreeNode]) {
            for node in nodes {
                ids.append(node.summary.id)
                walk(node.children)
            }
        }
        walk(tree)
        #expect(ids.count == 2)
        #expect(Set(ids) == [a, b])
    }

    @Test("Empty input yields an empty tree")
    func threadTreeEmpty() {
        #expect(ChatThreadHelpers.threadTree(from: []).isEmpty)
    }
}
