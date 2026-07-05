import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("VaultPaths — crash-recovery sidecar paths")
struct RecoveryPathsTests {

    @Test("Recovery directory lives under the ignored .punkrecords dir")
    func recoveryDirectoryLocation() {
        #expect(VaultPaths.recoveryDirectory == ".punkrecords/recovery")
    }

    @Test("Sidecar path is keyed by the note's uuid")
    func sidecarPathByID() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(
            VaultPaths.recoverySidecarPath(forNoteID: id)
                == ".punkrecords/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.md"
        )
    }

    @Test("Note id round-trips through the sidecar filename")
    func noteIDRoundTrip() {
        let id = UUID()
        let path = VaultPaths.recoverySidecarPath(forNoteID: id)
        let filename = (path as NSString).lastPathComponent
        #expect(VaultPaths.recoveryNoteID(fromSidecarFilename: filename) == id)
    }

    @Test("Non-sidecar filenames are rejected")
    func rejectsNonSidecarNames() {
        // In-flight temp files, non-uuid names, and wrong extensions all fail.
        #expect(VaultPaths.recoveryNoteID(fromSidecarFilename: "notes.md") == nil)
        #expect(VaultPaths.recoveryNoteID(fromSidecarFilename: "\(UUID().uuidString).tmp") == nil)
        #expect(VaultPaths.recoveryNoteID(fromSidecarFilename: "\(UUID().uuidString).txt") == nil)
        #expect(VaultPaths.recoveryNoteID(fromSidecarFilename: "README") == nil)
    }
}
