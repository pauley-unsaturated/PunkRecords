import Foundation
import PunkRecordsCore

/// Creates temporary vault directories for testing.
public struct TempVaultFactory: Sendable {
    public init() {}

    public func createTempVault(name: String = "TestVault") throws -> (vault: Vault, cleanup: @Sendable () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PunkRecordsTests")
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let punkDir = tempDir.appendingPathComponent(".punkrecords")
        try FileManager.default.createDirectory(at: punkDir, withIntermediateDirectories: true)

        let vault = Vault(name: name, rootURL: tempDir)

        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return (vault, cleanup)
    }

    public func writeTestDocument(
        _ content: String,
        filename: String,
        in vaultRoot: URL,
        subfolder: String? = nil
    ) throws {
        var dir = vaultRoot
        if let subfolder {
            dir = dir.appendingPathComponent(subfolder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
