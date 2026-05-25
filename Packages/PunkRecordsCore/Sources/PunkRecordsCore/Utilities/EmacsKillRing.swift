import Foundation

/// The Emacs kill-ring: a bounded, newest-first stack of killed/copied text
/// with a rotating read position for yank-pop (M-y). Pure value type so it can
/// be unit-tested without a text view; the editor owns one instance.
public struct EmacsKillRing: Sendable, Equatable {
    private var entries: [String] = []
    private var index: Int = 0
    private let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The entry that a yank (C-y) would insert — the most recent kill, or the
    /// current rotation position after a yank-pop.
    public var current: String? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// Record a kill/copy as the newest entry and reset the read position to it.
    /// No-ops on empty text so a zero-length region doesn't clobber the ring.
    public mutating func kill(_ text: String) {
        guard !text.isEmpty else { return }
        entries.insert(text, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        index = 0
    }

    /// Yank-pop: rotate to the next-older entry and return it. Returns nil when
    /// the ring is empty.
    public mutating func rotate() -> String? {
        guard !entries.isEmpty else { return nil }
        index = (index + 1) % entries.count
        return entries[index]
    }
}
