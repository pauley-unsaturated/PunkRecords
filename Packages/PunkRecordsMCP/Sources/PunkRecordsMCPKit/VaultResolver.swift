import Foundation

/// A vault path that failed to resolve to a usable directory.
public enum VaultResolutionError: Error, Equatable, CustomStringConvertible {
    case doesNotExist(String)
    case notADirectory(String)

    public var description: String {
        switch self {
        case .doesNotExist(let path):
            return "Vault path does not exist: \(path)"
        case .notADirectory(let path):
            return "Vault path is not a directory: \(path)"
        }
    }
}

/// Resolves a `punkrecords-mcp` vault root from CLI input.
///
/// Per PUNK-q9h's scope decision, ANY directory is a valid vault (the app
/// itself opens arbitrary directories as vaults — see `AppState.openVault`);
/// there is no `.punkrecords` marker file requirement. Resolution order:
/// explicit CLI path argument, else the process's current working directory.
public enum VaultResolver {
    /// - Parameters:
    ///   - cliPathArgument: The `--vault`/positional argument, if any.
    ///   - currentDirectoryPath: Fallback base when no argument is given, and
    ///     the base a relative argument is resolved against. Callers pass
    ///     `FileManager.default.currentDirectoryPath` in production; tests can
    ///     inject any string to keep this function pure/filesystem-free.
    ///   - fileExists: Injected filesystem check `(path) -> (exists, isDirectory)`,
    ///     so this stays a pure function under test (production callers pass a
    ///     `FileManager.default.fileExists(atPath:isDirectory:)` wrapper).
    public static func resolve(
        cliPathArgument: String?,
        currentDirectoryPath: String,
        fileExists: (String) -> (exists: Bool, isDirectory: Bool)
    ) -> Result<URL, VaultResolutionError> {
        let rawPath = cliPathArgument ?? currentDirectoryPath
        let expanded = (rawPath as NSString).expandingTildeInPath

        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            url = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded)
        }
        let standardized = url.standardizedFileURL

        let check = fileExists(standardized.path)
        guard check.exists else {
            return .failure(.doesNotExist(standardized.path))
        }
        guard check.isDirectory else {
            return .failure(.notADirectory(standardized.path))
        }
        return .success(standardized)
    }

    /// Production filesystem check backing `resolve(fileExists:)`.
    public static func liveFileExists(_ path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }
}
