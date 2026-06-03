import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("VaultOpenProgress Tests")
struct VaultOpenProgressTests {
    @Test("Reading phase is indeterminate")
    func readingHasNoFraction() {
        #expect(VaultOpenProgress(phase: .reading(notesRead: 0)).fractionCompleted == nil)
        #expect(VaultOpenProgress(phase: .reading(notesRead: 42)).fractionCompleted == nil)
    }

    @Test("Reading label omits the count until at least one note is read")
    func readingLabel() {
        #expect(VaultOpenProgress(phase: .reading(notesRead: 0)).label == "Reading notes…")
        #expect(VaultOpenProgress(phase: .reading(notesRead: 7)).label == "Reading notes… (7)")
    }

    @Test("Indexing fraction is completed / total")
    func indexingFraction() {
        #expect(VaultOpenProgress(phase: .indexing(completed: 0, total: 4)).fractionCompleted == 0.0)
        #expect(VaultOpenProgress(phase: .indexing(completed: 1, total: 4)).fractionCompleted == 0.25)
        #expect(VaultOpenProgress(phase: .indexing(completed: 4, total: 4)).fractionCompleted == 1.0)
    }

    @Test("Indexing fraction clamps completed into 0...total")
    func indexingFractionClamps() {
        #expect(VaultOpenProgress(phase: .indexing(completed: 9, total: 4)).fractionCompleted == 1.0)
        #expect(VaultOpenProgress(phase: .indexing(completed: -3, total: 4)).fractionCompleted == 0.0)
    }

    @Test("Indexing with zero total is treated as indeterminate")
    func indexingZeroTotal() {
        let progress = VaultOpenProgress(phase: .indexing(completed: 0, total: 0))
        #expect(progress.fractionCompleted == nil)
        #expect(progress.label == "Indexing notes…")
    }

    @Test("Indexing label shows completed of total")
    func indexingLabel() {
        #expect(
            VaultOpenProgress(phase: .indexing(completed: 3, total: 10)).label
                == "Indexing notes… (3 of 10)"
        )
    }
}
