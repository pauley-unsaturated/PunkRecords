import Foundation

/// Pure decisions for the chat-thread feature, lifted out of the controller /
/// store so they are unit-testable without SwiftUI or the filesystem: thread
/// title derivation, summary sorting, and the legacy-transcript migration gate.
public enum ChatThreadHelpers {
    /// Placeholder title for a thread with no user message yet.
    public static let defaultTitle = "New Chat"

    /// Longest derived title, in characters, before truncation.
    public static let maxTitleLength = 60

    /// Derive a thread title from its messages: the first user message, trimmed,
    /// with internal whitespace/newlines collapsed to single spaces and
    /// truncated (with an ellipsis) to ``maxTitleLength``. A thread with no
    /// non-empty user message falls back to ``defaultTitle`` so the switcher
    /// always has something to render.
    public static func deriveTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else {
            return defaultTitle
        }
        return deriveTitle(fromFirstUserMessage: first.content)
    }

    /// Derive a title from a single user-message body. Exposed separately so the
    /// derivation is testable on raw strings.
    public static func deriveTitle(fromFirstUserMessage text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return defaultTitle }

        guard collapsed.count > maxTitleLength else { return collapsed }
        let clipped = collapsed.prefix(maxTitleLength)
            .trimmingCharacters(in: .whitespaces)
        return clipped + "…"
    }

    // MARK: - Forking

    /// Fork a conversation at a specific message: produce a NEW ``ChatThread``
    /// containing `source`'s messages up to AND INCLUDING the message with
    /// `messageID`, carrying lineage back to `source` (``ChatThread/parentThreadID``
    /// = `source.id`, ``ChatThread/forkedAtMessageID`` = `messageID`). Returns
    /// `nil` when `messageID` is not present in `source` — nothing to fork.
    ///
    /// The `source` is never mutated (value semantics). Forking at the last
    /// message yields a full copy with lineage; forking at the first yields a
    /// single-message thread. The fork's title is derived from its sliced
    /// messages, so a fork made at (or after) the first user message shares the
    /// source's title — that overlap is acceptable; the lineage fields, not the
    /// title, carry the branch relationship.
    ///
    /// `newThreadID` and `now` are injected (with `UUID()` / `Date()` defaults) so
    /// the result is deterministic under test, matching the clock-as-parameter
    /// precedent of ``ChatThread/update(messages:now:)`` — no non-deterministic
    /// value is read inside the function body.
    public static func fork(
        _ source: ChatThread,
        atMessageID messageID: UUID,
        newThreadID: UUID = UUID(),
        now: Date = Date()
    ) -> ChatThread? {
        guard let index = source.messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        let sliced = Array(source.messages[...index])
        return ChatThread(
            id: newThreadID,
            title: deriveTitle(from: sliced),
            createdAt: now,
            updatedAt: now,
            parentThreadID: source.id,
            forkedAtMessageID: messageID,
            messages: sliced
        )
    }

    // MARK: - Rewind

    /// Rewind `messages` to `messageID`: keep every message up to AND INCLUDING
    /// it, dropping everything after — the inverse slice direction from
    /// ``fork(_:atMessageID:newThreadID:now:)`` (which also keeps through the
    /// target) but applied in place to a live transcript rather than spawning a
    /// new thread. Returns `nil` when `messageID` isn't present in `messages` —
    /// nothing to rewind, so the caller should treat it as a no-op rather than
    /// persist an unchanged transcript.
    ///
    /// Rewinding at the last message is a no-op-shaped full copy (nothing
    /// dropped); rewinding at the first message yields a single-message
    /// transcript. `messages` is never mutated (value semantics).
    public static func rewind(_ messages: [ChatMessage], to messageID: UUID) -> [ChatMessage]? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        return Array(messages[...index])
    }

    /// Vault-relative paths of notes created via `create_note` tool calls among
    /// `messages` — used to warn the user, before a rewind, that those notes are
    /// NOT deleted along with the rewound-away turns (silently deleting vault
    /// content on rewind would be worse than leaving it behind).
    ///
    /// Scans `.tool`-role rows for a completed (not in-flight), non-error
    /// `create_note` call and parses the created path out of
    /// ``CreateNoteTool``'s success message (`"Created note '<title>' at
    /// <path>"`) rather than the call's `arguments` — arguments only reflect
    /// what was REQUESTED (e.g. before a filename-collision suffix is applied),
    /// while the tool result reflects what actually landed on disk. This couples
    /// the parse to `CreateNoteTool`'s output phrasing; if that ever changes
    /// independently, this scan starts returning fewer paths (never wrong ones,
    /// since a non-matching output is simply skipped) rather than crashing.
    public static func createdNotePaths(in messages: [ChatMessage]) -> [String] {
        messages.compactMap { message in
            guard message.role == .tool,
                  let toolCall = message.toolCall,
                  toolCall.name == "create_note",
                  !toolCall.isError,
                  !toolCall.isInFlight else { return nil }
            return createdNotePath(fromToolOutput: toolCall.output)
        }
    }

    /// Parses `"Created note '<title>' at <path>"` (``CreateNoteTool``'s success
    /// message) for the trailing path. Searches for the LAST " at " so a title
    /// that itself contains the substring " at " doesn't fool the split.
    private static func createdNotePath(fromToolOutput output: String) -> String? {
        guard let range = output.range(of: " at ", options: .backwards) else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Summaries sorted for the switcher: most-recently-updated first, with a
    /// stable id tiebreak so equal timestamps order deterministically.
    public static func sortedSummaries(_ summaries: [ThreadSummary]) -> [ThreadSummary] {
        summaries.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    // MARK: - Sidebar thread tree

    /// A node in the sidebar's thread tree: a thread summary plus its forked
    /// children (each itself a node). Children are the threads whose
    /// ``ThreadSummary/parentThreadID`` points at this node's thread.
    public struct ThreadTreeNode: Identifiable, Equatable, Sendable {
        public let summary: ThreadSummary
        public let children: [ThreadTreeNode]
        public var id: UUID { summary.id }

        public init(summary: ThreadSummary, children: [ThreadTreeNode] = []) {
            self.summary = summary
            self.children = children
        }
    }

    /// Assemble a parent → children tree from flat ``ThreadSummary`` rows for the
    /// sidebar's Chats section. A thread nests under its ``parentThreadID`` when
    /// that parent is also present; otherwise it is a top-level row. Every summary
    /// appears EXACTLY ONCE:
    /// - **Orphaned parent** (parent id not in the set) ⇒ the child surfaces as a
    ///   flat top-level row.
    /// - **Self-parent / cycles** ⇒ broken safely: a node never becomes its own
    ///   ancestor, and any summary trapped in a pure cycle (never reachable from a
    ///   root) is surfaced as a flat top-level row rather than dropped.
    ///
    /// Rows are sorted newest-first within each level via ``sortedSummaries(_:)``.
    public static func threadTree(from summaries: [ThreadSummary]) -> [ThreadTreeNode] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var childrenByParent: [UUID: [ThreadSummary]] = [:]
        var rootCandidates: [ThreadSummary] = []
        for summary in summaries {
            if let parentID = summary.parentThreadID,
               parentID != summary.id,
               byID[parentID] != nil {
                childrenByParent[parentID, default: []].append(summary)
            } else {
                // No parent, an orphaned parent reference, or a self-parent.
                rootCandidates.append(summary)
            }
        }

        var emitted = Set<UUID>()
        func build(_ summary: ThreadSummary) -> ThreadTreeNode {
            emitted.insert(summary.id)
            let kids = (childrenByParent[summary.id] ?? []).filter { !emitted.contains($0.id) }
            return ThreadTreeNode(summary: summary, children: sortedSummaries(kids).map(build))
        }

        var roots = sortedSummaries(rootCandidates).map(build)

        // Any summary trapped in a pure cycle (A→B→A, so neither is a root) was
        // never emitted; surface such threads as flat top-level rows so nothing
        // vanishes. Re-check `emitted` per iteration: building one cycle member
        // emits the rest, which must then be skipped (never double-listed).
        let leftover = summaries.filter { !emitted.contains($0.id) }
        for summary in sortedSummaries(leftover) where !emitted.contains(summary.id) {
            roots.append(build(summary))
        }
        return roots
    }

    /// Whether the legacy single-transcript persistence should be converted into
    /// a thread on first open. Migrate exactly once: only when there is legacy
    /// content AND no threads exist yet, so a user who has already migrated (or
    /// who started fresh on the thread format) is never re-migrated.
    public static func shouldMigrateLegacyTranscript(
        hasLegacyContent: Bool,
        hasExistingThreads: Bool
    ) -> Bool {
        hasLegacyContent && !hasExistingThreads
    }
}
