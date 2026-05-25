import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("EmacsKillRing Tests")
struct EmacsKillRingTests {
    @Test("New ring is empty with no current entry")
    func emptyRing() {
        let ring = EmacsKillRing()
        #expect(ring.isEmpty)
        #expect(ring.current == nil)
    }

    @Test("Kill makes the newest entry current")
    func killNewestCurrent() {
        var ring = EmacsKillRing()
        ring.kill("first")
        ring.kill("second")
        #expect(ring.current == "second")
        #expect(!ring.isEmpty)
    }

    @Test("Empty kills are ignored")
    func emptyKillIgnored() {
        var ring = EmacsKillRing()
        ring.kill("")
        #expect(ring.isEmpty)
    }

    @Test("Rotate cycles to older entries and wraps")
    func rotateCycles() {
        var ring = EmacsKillRing()
        ring.kill("a")   // oldest
        ring.kill("b")
        ring.kill("c")   // newest, current
        #expect(ring.current == "c")
        #expect(ring.rotate() == "b")
        #expect(ring.rotate() == "a")
        #expect(ring.rotate() == "c") // wraps back to newest
    }

    @Test("Kill after rotate resets the read position to newest")
    func killResetsIndex() {
        var ring = EmacsKillRing()
        ring.kill("a")
        ring.kill("b")
        _ = ring.rotate()        // now at "a"
        ring.kill("c")
        #expect(ring.current == "c")
    }

    @Test("Capacity evicts the oldest entries")
    func capacityEviction() {
        var ring = EmacsKillRing(capacity: 2)
        ring.kill("a")
        ring.kill("b")
        ring.kill("c")           // evicts "a"
        #expect(ring.current == "c")
        #expect(ring.rotate() == "b")
        #expect(ring.rotate() == "c") // only 2 entries; "a" gone
    }

    @Test("Rotate on empty ring returns nil")
    func rotateEmpty() {
        var ring = EmacsKillRing()
        #expect(ring.rotate() == nil)
    }
}
