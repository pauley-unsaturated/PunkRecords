import Foundation
import MCP
import PunkRecordsInfra

/// Writes a line to stderr. The MCP stdio transport uses stdout as the wire —
/// nothing but JSON-RPC frames may ever be written there once the transport
/// starts, so every diagnostic in this file goes to stderr instead.
func logDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Exit codes `run(arguments:)` signals via `RunnerExit`, matched by
/// `main.swift` to a process exit status.
public enum RunnerExit: Equatable {
    case success
    case failure(String)
}

/// Top-level entry point shared by `main.swift` and tests. Parses CLI
/// arguments, resolves the vault, indexes it, and — unless `--help`/`--version`
/// short-circuits first — runs the MCP server over stdio until the client
/// disconnects.
public enum Runner {
    public static func run(arguments: [String]) async -> RunnerExit {
        let options: CLIOptions
        switch CLIParser.parse(arguments) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            logDiagnostic("\(error)\n\n\(cliUsageText)")
            return .failure(error.description)
        }

        if options.showHelp {
            print(cliUsageText)
            return .success
        }
        if options.showVersion {
            print(ServerFactory.serverVersion)
            return .success
        }

        let vaultRoot: URL
        switch VaultResolver.resolve(
            cliPathArgument: options.vaultPathArgument,
            currentDirectoryPath: FileManager.default.currentDirectoryPath,
            fileExists: VaultResolver.liveFileExists
        ) {
        case .success(let url):
            vaultRoot = url
        case .failure(let error):
            logDiagnostic(error.description)
            return .failure(error.description)
        }

        logDiagnostic("[punkrecords-mcp] opening vault at \(vaultRoot.path) (writable: \(options.writable))")

        let repository = FileSystemDocumentRepository(vaultRoot: vaultRoot, ignoredPaths: [])
        let searchIndex: SQLiteSearchIndex
        do {
            searchIndex = try SQLiteSearchIndex(vaultRoot: vaultRoot)
        } catch {
            let message = "Failed to open search index at \(vaultRoot.path): \(error.localizedDescription)"
            logDiagnostic(message)
            return .failure(message)
        }

        // Mirror AppState.openVault's initial indexing pass: the FTS index is
        // derived data (`.punkrecords/index.sqlite`), rebuilt from the .md
        // files on open. Unlike the app, this server does NOT watch for
        // filesystem changes afterward — it indexes once at startup, so
        // edits made outside this process while it's running won't be
        // reflected until it's restarted. That's an accepted limitation for
        // this thin wrapper; see README.md.
        do {
            let documents = try await repository.allDocuments()
            try await searchIndex.rebuildIndex(documents: documents)
            logDiagnostic("[punkrecords-mcp] indexed \(documents.count) document(s)")
        } catch {
            let message = "Failed to index vault at \(vaultRoot.path): \(error.localizedDescription)"
            logDiagnostic(message)
            return .failure(message)
        }

        let tools = ServerFactory.makeTools(repository: repository, searchService: searchIndex)
        let server = await ServerFactory.makeServer(tools: tools, writable: options.writable)

        do {
            try await server.start(transport: StdioTransport())
        } catch {
            let message = "Failed to start MCP transport: \(error.localizedDescription)"
            logDiagnostic(message)
            return .failure(message)
        }

        await server.waitUntilCompleted()
        return .success
    }
}
