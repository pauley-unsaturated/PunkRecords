import Foundation

/// A persisted chat conversation: an ordered list of ``ChatMessage`` rows plus
/// the metadata the thread list and future forking need. One thread maps to one
/// JSON file on disk (see `FileSystemThreadStore`).
///
/// `parentThreadID` / `forkedAtMessageID` are reserved for a follow-up
/// conversation-forking feature — they are serialized now so the on-disk format
/// does not churn when forking lands. They are `nil` for threads created by the
/// current "new chat" flow.
public struct ChatThread: Identifiable, Codable, Sendable, Equatable {
    /// Bumped when the on-disk shape changes so future migrations are cheap.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    /// The thread this one was forked from, if any. Reserved for forking (PUNK-9up).
    public var parentThreadID: UUID?
    /// The message in the parent thread at which this fork branched. Reserved.
    public var forkedAtMessageID: UUID?
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = ChatThreadHelpers.defaultTitle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        parentThreadID: UUID? = nil,
        forkedAtMessageID: UUID? = nil,
        messages: [ChatMessage] = [],
        schemaVersion: Int = ChatThread.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentThreadID = parentThreadID
        self.forkedAtMessageID = forkedAtMessageID
        self.messages = messages
        self.schemaVersion = schemaVersion
    }

    /// Lightweight projection for list rendering (no message bodies).
    public var summary: ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            updatedAt: updatedAt,
            messageCount: messages.count,
            hasParent: parentThreadID != nil
        )
    }

    /// Replace the thread's messages, re-derive its title from the first user
    /// message, and stamp `updatedAt`. Used by the controller after each turn so
    /// a saved thread always reflects its latest content.
    public mutating func update(messages: [ChatMessage], now: Date = Date()) {
        self.messages = messages
        self.title = ChatThreadHelpers.deriveTitle(from: messages)
        self.updatedAt = now
    }

    /// Decodes leniently so threads written by an older build without a
    /// `schemaVersion` key still load (defaulting to v1), keeping the versioning
    /// field cheap to add without a hard migration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ChatThread.currentSchemaVersion
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.parentThreadID = try c.decodeIfPresent(UUID.self, forKey: .parentThreadID)
        self.forkedAtMessageID = try c.decodeIfPresent(UUID.self, forKey: .forkedAtMessageID)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
    }
}

/// A thread's list-row metadata: everything needed to render and sort the thread
/// switcher without loading full message bodies into memory.
public struct ThreadSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
    /// Whether the underlying thread was forked from another (i.e. carries a
    /// ``ChatThread/parentThreadID``). Lets the switcher flag forked rows without
    /// loading full threads. Defaults to `false` and decodes leniently so older
    /// callers / any pre-existing serialization stay valid.
    public let hasParent: Bool

    public init(
        id: UUID,
        title: String,
        updatedAt: Date,
        messageCount: Int,
        hasParent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.hasParent = hasParent
    }

    /// Decodes `hasParent` leniently (defaulting to `false` when absent) so the
    /// field is a cheap, non-breaking addition — mirroring ``ChatThread``'s
    /// lenient `schemaVersion` decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messageCount = try c.decode(Int.self, forKey: .messageCount)
        self.hasParent = try c.decodeIfPresent(Bool.self, forKey: .hasParent) ?? false
    }
}
