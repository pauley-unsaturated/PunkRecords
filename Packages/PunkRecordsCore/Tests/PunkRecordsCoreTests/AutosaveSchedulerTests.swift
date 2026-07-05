import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("AutosaveScheduler — debounce + periodic backstop")
struct AutosaveSchedulerTests {

    // A fixed reference instant keeps the arithmetic readable.
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("Debounce dominates shortly after a save")
    func debounceDominates() {
        // Saved 1s ago, edited just now → the debounce deadline (edit + 1.5s)
        // arrives before the periodic one (save + 30s), so it wins.
        let deadline = AutosaveScheduler.fireDeadline(
            lastEditTime: t0,
            lastSaveTime: t0.addingTimeInterval(-1)
        )
        #expect(deadline == t0.addingTimeInterval(1.5))
    }

    @Test("Periodic backstop dominates under continuous typing")
    func periodicDominates() {
        // Still typing (edit is "now"), but the last durable save was 29s ago.
        // The periodic deadline (save + 30s = t0 + 1s) is earlier than the
        // debounce deadline (edit + 1.5s), so it wins — bounding data loss.
        let lastSave = t0.addingTimeInterval(-29)
        let deadline = AutosaveScheduler.fireDeadline(
            lastEditTime: t0,
            lastSaveTime: lastSave
        )
        #expect(deadline == lastSave.addingTimeInterval(30))
        #expect(deadline == t0.addingTimeInterval(1))
    }

    @Test("Periodic deadline is fixed to the last save, not the moving edit")
    func periodicAnchoredToSave() {
        // Continuous typing near the 30s mark: two edits 0.5s apart, both far
        // enough past the last save that the periodic deadline is the earlier
        // one. It stays anchored to the (unchanged) save, so both edits resolve
        // to the same absolute fire instant despite the moving edit time.
        let lastSave = t0
        let firstEdit = t0.addingTimeInterval(29)
        let secondEdit = t0.addingTimeInterval(29.5)
        let d1 = AutosaveScheduler.fireDeadline(lastEditTime: firstEdit, lastSaveTime: lastSave)
        let d2 = AutosaveScheduler.fireDeadline(lastEditTime: secondEdit, lastSaveTime: lastSave)
        #expect(d1 == lastSave.addingTimeInterval(30))
        #expect(d2 == lastSave.addingTimeInterval(30))
        #expect(d1 == d2)
    }

    @Test("delayUntilFire clamps a passed deadline to zero")
    func delayClampsToZero() {
        // Deadline already elapsed (edit + save both well in the past) → fire
        // immediately, never a negative sleep.
        let delay = AutosaveScheduler.delayUntilFire(
            lastEditTime: t0.addingTimeInterval(-100),
            lastSaveTime: t0.addingTimeInterval(-100),
            now: t0
        )
        #expect(delay == 0)
    }

    @Test("delayUntilFire returns the remaining time to the debounce deadline")
    func delayCountsRemaining() {
        // Saved just now, edited 0.5s ago → 1.5s debounce means 1.0s remains,
        // and the periodic deadline (save + 30s) is comfortably later.
        let delay = AutosaveScheduler.delayUntilFire(
            lastEditTime: t0.addingTimeInterval(-0.5),
            lastSaveTime: t0,
            now: t0
        )
        #expect(abs(delay - 1.0) < 0.0001)
    }

    @Test("Custom intervals are honored")
    func customIntervals() {
        // Recent save so the debounce (custom 3s) is the earlier deadline.
        let deadline = AutosaveScheduler.fireDeadline(
            lastEditTime: t0,
            lastSaveTime: t0,
            debounceInterval: 3,
            periodicInterval: 60
        )
        #expect(deadline == t0.addingTimeInterval(3))
    }

    @Test("A long-overdue periodic deadline fires immediately")
    func overduePeriodicFiresNow() {
        // If the last durable save is older than the periodic window while edits
        // keep landing, the periodic deadline is already in the past → fire now.
        let delay = AutosaveScheduler.delayUntilFire(
            lastEditTime: t0,
            lastSaveTime: t0.addingTimeInterval(-100),
            now: t0
        )
        #expect(delay == 0)
    }

    @Test("Default intervals match the spec (1.5s debounce, 30s periodic)")
    func defaultIntervals() {
        #expect(AutosaveScheduler.debounceInterval == 1.5)
        #expect(AutosaveScheduler.periodicInterval == 30)
    }
}
