import Foundation
import Testing
@testable import PunkRecordsMCPKit

@Suite("VaultResolver — vault path resolution")
struct VaultResolverTests {
    /// Extracts the resolved path, failing the test if `result` isn't
    /// `.success`. Compares `URL.path` rather than the `URL` itself —
    /// `URL(fileURLWithPath:isDirectory:)` construction isn't guaranteed to
    /// round-trip a trailing slash identically through `standardizedFileURL`,
    /// which made whole-`URL` equality an implementation-detail-sensitive
    /// assertion. The path string is what the rest of the app (and tests)
    /// actually care about.
    private func resolvedPath(_ result: Result<URL, VaultResolutionError>) -> String? {
        guard case let .success(url) = result else { return nil }
        return url.path
    }

    @Test("no CLI argument falls back to the current working directory")
    func defaultsToCWD() {
        let result = VaultResolver.resolve(
            cliPathArgument: nil,
            currentDirectoryPath: "/Users/test/vault",
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        #expect(resolvedPath(result) == "/Users/test/vault")
    }

    @Test("an absolute CLI argument is used as-is")
    func absolutePath() {
        let result = VaultResolver.resolve(
            cliPathArgument: "/Volumes/External/MyVault",
            currentDirectoryPath: "/Users/test",
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        #expect(resolvedPath(result) == "/Volumes/External/MyVault")
    }

    @Test("a relative CLI argument resolves against currentDirectoryPath, not the real process CWD")
    func relativePathResolvesAgainstInjectedCWD() {
        let result = VaultResolver.resolve(
            cliPathArgument: "sub/vault",
            currentDirectoryPath: "/Users/test",
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        #expect(resolvedPath(result) == "/Users/test/sub/vault")
    }

    @Test("tilde in a CLI argument is expanded")
    func tildeExpansion() {
        let result = VaultResolver.resolve(
            cliPathArgument: "~/MyVault",
            currentDirectoryPath: "/Users/test",
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        let expected = (NSHomeDirectory() as NSString).appendingPathComponent("MyVault")
        #expect(resolvedPath(result) == expected)
    }

    @Test("a path that doesn't exist is reported")
    func doesNotExist() {
        let result = VaultResolver.resolve(
            cliPathArgument: "/nowhere",
            currentDirectoryPath: "/Users/test",
            fileExists: { _ in (exists: false, isDirectory: false) }
        )
        #expect(result == .failure(.doesNotExist("/nowhere")))
    }

    @Test("a path that resolves to a file (not a directory) is reported")
    func notADirectory() {
        let result = VaultResolver.resolve(
            cliPathArgument: "/Users/test/note.md",
            currentDirectoryPath: "/Users/test",
            fileExists: { _ in (exists: true, isDirectory: false) }
        )
        #expect(result == .failure(.notADirectory("/Users/test/note.md")))
    }
}
