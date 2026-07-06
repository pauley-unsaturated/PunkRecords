import Foundation

/// The note a conversation is "about", captured for list display. Persisted on
/// the thread (and projected into ``ThreadSummary``) so the sidebar / switcher
/// can name it WITHOUT loading full message bodies. Derived at save time from the
/// most recent message with a resolvable note context (see
/// ``ChatNoteContext/focusNote(for:resolveDocument:)``).
public struct ThreadFocusNote: Codable, Sendable, Equatable {
    /// Human-readable note title for the row subtitle / header chip.
    public let title: String
    /// Vault-relative path — the navigation target (set `selectedDocumentPath`).
    public let path: RelativePath

    public init(title: String, path: RelativePath) {
        self.title = title
        self.path = path
    }
}

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
    /// The note this conversation is about, if any — the most recent message with
    /// a resolvable note context. Computed on ``update(messages:focusNote:now:)``
    /// so the switcher can show it without loading bodies. `nil` for vault-wide
    /// conversations (and for pre-existing threads written before this field).
    public var focusNote: ThreadFocusNote?
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = ChatThreadHelpers.defaultTitle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        parentThreadID: UUID? = nil,
        forkedAtMessageID: UUID? = nil,
        focusNote: ThreadFocusNote? = nil,
        messages: [ChatMessage] = [],
        schemaVersion: Int = ChatThread.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentThreadID = parentThreadID
        self.forkedAtMessageID = forkedAtMessageID
        self.focusNote = focusNote
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
            parentThreadID: parentThreadID,
            focusNote: focusNote
        )
    }

    /// Replace the thread's messages, re-derive its title from the first user
    /// message, refresh the focus note, and stamp `updatedAt`. Used by the
    /// controller after each turn so a saved thread always reflects its latest
    /// content. `focusNote` is resolved by the caller (which has the vault) and
    /// passed in — keeping this pure Core with no repository dependency.
    public mutating func update(
        messages: [ChatMessage],
        focusNote: ThreadFocusNote? = nil,
        now: Date = Date()
    ) {
        self.messages = messages
        self.title = ChatThreadHelpers.deriveTitle(from: messages)
        self.focusNote = focusNote
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
        // Additive, lenient: a thread written before focus notes existed simply
        // has no key, so it loads with `nil` (row shows the title only).
        self.focusNote = try c.decodeIfPresent(ThreadFocusNote.self, forKey: .focusNote)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
    }
}

/// A thread's list-row metadata: everything needed to render, nest, and sort the
/// thread switcher without loading full message bodies into memory.
public struct ThreadSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
    /// The thread this one was forked from, if any. Drives branch nesting in the
    /// sidebar (parent → children) and the forked-row flag. Decodes leniently
    /// (absent ⇒ `nil`) so it's a cheap, non-breaking addition — mirroring
    /// ``ChatThread``'s lenient `schemaVersion` decode.
    public let parentThreadID: UUID?
    /// The note this conversation is about, if any — shown as a secondary row
    /// subtitle. Decodes leniently (absent ⇒ `nil`) so a summary from a thread
    /// written before focus notes existed still lists (title only).
    public let focusNote: ThreadFocusNote?

    /// Whether the underlying thread was forked from another (i.e. carries a
    /// ``parentThreadID``). Lets the switcher flag forked rows without loading
    /// full threads.
    public var hasParent: Bool { parentThreadID != nil }

    public init(
        id: UUID,
        title: String,
        updatedAt: Date,
        messageCount: Int,
        parentThreadID: UUID? = nil,
        focusNote: ThreadFocusNote? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.parentThreadID = parentThreadID
        self.focusNote = focusNote
    }

    /// Decodes the additive `parentThreadID` / `focusNote` leniently (absent ⇒
    /// `nil`) so the fields are cheap, non-breaking additions — mirroring
    /// ``ChatThread``'s lenient `schemaVersion` decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messageCount = try c.decode(Int.self, forKey: .messageCount)
        self.parentThreadID = try c.decodeIfPresent(UUID.self, forKey: .parentThreadID)
        self.focusNote = try c.decodeIfPresent(ThreadFocusNote.self, forKey: .focusNote)
    }
}
