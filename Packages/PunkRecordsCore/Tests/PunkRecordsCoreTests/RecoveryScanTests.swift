import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("RecoveryScan — recoverable vs stale sidecars")
struct RecoveryScanTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    @Test("Newer sidecar with different content is recoverable")
    func newerDifferingIsRecoverable() {
        let id = UUID()
        let sidecar = RecoverySidecar(
            noteID: id,
            content: "unsaved work",
            modified: t0.addingTimeInterval(10)
        )
        let notes = [id: RecoveryNoteState(content: "on disk", modified: t0)]

        let result = RecoveryScan.scan(sidecars: [sidecar], notes: notes)

        #expect(result.stale.isEmpty)
        #expect(result.recoverable.count == 1)
        #expect(result.recoverable.first?.noteID == id)
        #expect(result.recoverable.first?.recoveredContent == "unsaved work")
        #expect(result.recoverable.first?.noteExistsOnDisk == true)
    }

    @Test("Sidecar matching the note is stale (leftover from a clean save)")
    func matchingContentIsStale() {
        let id = UUID()
        let sidecar = RecoverySidecar(noteID: id, content: "same", modified: t0.addingTimeInterval(10))
        let notes = [id: RecoveryNoteState(content: "same", modified: t0)]

        let result = RecoveryScan.scan(sidecars: [sidecar], notes: notes)

        #expect(result.recoverable.isEmpty)
        #expect(result.stale == [id])
    }

    @Test("Note newer than a differing sidecar wins — sidecar is stale")
    func noteNewerThanSidecarIsStale() {
        // e.g. the note was edited on another device / by a sync after the
        // sidecar was written. Honor the note; don't clobber it.
        let id = UUID()
        let sidecar = RecoverySidecar(noteID: id, content: "old unsaved", modified: t0)
        let notes = [id: RecoveryNoteState(content: "newer saved", modified: t0.addingTimeInterval(10))]

        let result = RecoveryScan.scan(sidecars: [sidecar], notes: notes)

        #expect(result.recoverable.isEmpty)
        #expect(result.stale == [id])
    }

    @Test("Equal timestamps with differing content are treated as stale (note wins)")
    func equalTimestampsAreStale() {
        // Only a strictly-newer sidecar recovers; a tie defers to the note.
        let id = UUID()
        let sidecar = RecoverySidecar(noteID: id, content: "a", modified: t0)
        let notes = [id: RecoveryNoteState(content: "b", modified: t0)]

        let result = RecoveryScan.scan(sidecars: [sidecar], notes: notes)

        #expect(result.recoverable.isEmpty)
        #expect(result.stale == [id])
    }

    @Test("Sidecar with no surviving note is recoverable and flagged missing")
    func missingNoteIsRecoverable() {
        let id = UUID()
        let sidecar = RecoverySidecar(noteID: id, content: "lost note body", modified: t0)

        let result = RecoveryScan.scan(sidecars: [sidecar], notes: [:])

        #expect(result.stale.isEmpty)
        #expect(result.recoverable.count == 1)
        #expect(result.recoverable.first?.noteExistsOnDisk == false)
        #expect(result.recoverable.first?.recoveredContent == "lost note body")
    }

    @Test("A mixed batch is classified independently")
    func mixedBatch() {
        let recoverID = UUID()
        let staleID = UUID()
        let missingID = UUID()

        let sidecars = [
            RecoverySidecar(noteID: recoverID, content: "new", modified: t0.addingTimeInterval(5)),
            RecoverySidecar(noteID: staleID, content: "same", modified: t0.addingTimeInterval(5)),
            RecoverySidecar(noteID: missingID, content: "orphan", modified: t0)
        ]
        let notes = [
            recoverID: RecoveryNoteState(content: "old", modified: t0),
            staleID: RecoveryNoteState(content: "same", modified: t0)
        ]

        let result = RecoveryScan.scan(sidecars: sidecars, notes: notes)

        #expect(Set(result.recoverable.map(\.noteID)) == [recoverID, missingID])
        #expect(result.stale == [staleID])
    }
}
