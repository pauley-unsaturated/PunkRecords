import Foundation

/// Pure scheduling decisions for editor autosave. Lives in Core so the timing
/// policy — "when should the next durable save fire?" — is unit-tested without
/// standing up an `NSTextView`, a `Task` timer, or the file system. The view
/// model becomes a thin shell that sleeps until the returned deadline.
///
/// Two overlapping rules drive the deadline:
///   - **Debounce (1.5s):** save 1.5s after the *last* edit. Resets on every
///     keystroke, so a burst of typing coalesces into a single write once the
///     user pauses.
///   - **Periodic safety (30s):** save 30s after the *last durable save*,
///     regardless of continued typing. This deadline does NOT reset while the
///     user keeps typing, so it bounds worst-case data loss to ~30s even if the
///     user never pauses long enough for the debounce to elapse.
///
/// The effective fire time is the *earlier* of the two, so a natural pause
/// triggers the debounce and relentless typing still gets caught by the
/// periodic backstop.
public enum AutosaveScheduler {

    /// Delay after the last edit before a debounced autosave fires.
    public static let debounceInterval: TimeInterval = 1.5

    /// Maximum time a durable save may lag behind ongoing edits.
    public static let periodicInterval: TimeInterval = 30

    /// Absolute time at which an autosave should fire.
    ///
    /// - Parameters:
    ///   - lastEditTime: when the most recent edit landed (resets the debounce).
    ///   - lastSaveTime: when the note was last durably written to disk (anchors
    ///     the periodic backstop). For a never-saved-since-open note, pass the
    ///     time the editor opened / loaded the note.
    ///   - debounceInterval: override for the 1.5s default (tests).
    ///   - periodicInterval: override for the 30s default (tests).
    /// - Returns: the earlier of `lastEditTime + debounceInterval` and
    ///   `lastSaveTime + periodicInterval`.
    public static func fireDeadline(
        lastEditTime: Date,
        lastSaveTime: Date,
        debounceInterval: TimeInterval = debounceInterval,
        periodicInterval: TimeInterval = periodicInterval
    ) -> Date {
        let debounceDeadline = lastEditTime.addingTimeInterval(debounceInterval)
        let periodicDeadline = lastSaveTime.addingTimeInterval(periodicInterval)
        return min(debounceDeadline, periodicDeadline)
    }

    /// Non-negative delay from `now` until the next autosave should fire. A
    /// deadline already in the past clamps to zero (fire immediately).
    public static func delayUntilFire(
        lastEditTime: Date,
        lastSaveTime: Date,
        now: Date,
        debounceInterval: TimeInterval = debounceInterval,
        periodicInterval: TimeInterval = periodicInterval
    ) -> TimeInterval {
        let deadline = fireDeadline(
            lastEditTime: lastEditTime,
            lastSaveTime: lastSaveTime,
            debounceInterval: debounceInterval,
            periodicInterval: periodicInterval
        )
        return max(0, deadline.timeIntervalSince(now))
    }
}
