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
