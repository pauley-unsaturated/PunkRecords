import Foundation
import MCP
import PunkRecordsTestSupport
import Testing

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// End-to-end smoke test: builds `punkrecords-mcp`, launches it as a real
/// subprocess against a throwaway vault, and speaks `initialize` + `tools/list`
/// + `tools/call` to it over actual stdin/stdout pipes using the same MCP
/// `Client` a real MCP host would use.
///
/// Tradeoff (per PUNK-q9h): this is the most faithful test available — it
/// exercises the real binary, the real `StdioTransport` framing, and process
/// spawn/teardown — at the cost of being more environment-sensitive (depends
/// on locating a build product on disk) than a purely in-process test.
/// `MCPToolAdapterTests` covers the same adapter logic in-process/
/// synchronously as a faster, non-flaky complement; if this test proves
/// flaky in CI, that in-process coverage is the fallback the issue
/// anticipated.
@Suite("End-to-end: real punkrecords-mcp subprocess over stdio")
struct EndToEndSmokeTests {
    private enum SmokeTestError: Error {
        case cannotLocateBinary(String)
    }

    /// Locates the already-built `punkrecords-mcp` binary.
    ///
    /// `punkrecords-mcp` is listed as a (non-imported) dependency of this
    /// test target in Package.swift specifically so `swift test`'s build
    /// graph builds it before any test runs — deliberately NOT by shelling
    /// out to a nested `swift build` from inside a test, which deadlocks:
    /// the outer `swift test` process holds this package's `.build` lock for
    /// its entire run, and a spawned `swift build` on the same package blocks
    /// forever waiting for that same lock.
    ///
    /// Products land next to the `.xctest` bundle Swift Testing runs from
    /// (`.build/<triple>/debug/`). `swift test` on this toolchain runs tests
    /// via `swiftpm-testing-helper --test-bundle-path <path-to-.xctest-binary>
    /// ... <same path> --testing-library swift-testing` — that path is
    /// visible in `CommandLine.arguments`, so it's used directly rather than
    /// the classic `Bundle.allBundles` "productsDirectory" trick, which
    /// proved to be a lazily-populated cache here (empty until something else
    /// happened to touch `Bundle.main` first) and so an unnecessarily fragile
    /// signal to depend on.
    private func locateBinary() throws -> URL {
        guard let xctestPath = CommandLine.arguments.first(where: { $0.contains(".xctest/Contents/MacOS/") }) else {
            throw SmokeTestError.cannotLocateBinary(
                "no .xctest path found in CommandLine.arguments: \(CommandLine.arguments)"
            )
        }
        // .../<products-dir>/Foo.xctest/Contents/MacOS/Foo -> products dir is 4 levels up.
        let productsDirectory = URL(fileURLWithPath: xctestPath)
            .deletingLastPathComponent() // Foo (the Mach-O itself)
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Foo.xctest
        let binary = productsDirectory.appendingPathComponent("punkrecords-mcp")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw SmokeTestError.cannotLocateBinary(binary.path)
        }
        return binary
    }

    /// Spawns `binary` with `arguments`, wiring its stdin/stdout to pipes the
    /// caller can hand an MCP `Client`'s `StdioTransport`.
    private func launch(binary: URL, arguments: [String]) throws -> (process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        // Parent writes -> child's stdin; child writes -> parent reads its stdout.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Route the child's diagnostics (stderr) to the parent's stderr rather
        // than an unread pipe, so a hang doesn't also deadlock on a full
        // stderr pipe buffer.
        process.standardError = FileHandle.standardError

        try process.run()
        return (process, stdinPipe, stdoutPipe)
    }

    private func makeTransport(stdinPipe: Pipe, stdoutPipe: Pipe) -> StdioTransport {
        StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
    }

    private func shutdown(process: Process, client: Client) async {
        await client.disconnect()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    @Test("initialize + tools/list + tools/call(list_documents) against a real subprocess")
    func fullConversation() async throws {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault(name: "MCPSmokeTestVault")
        defer { cleanup() }
        try factory.writeTestDocument(
            "---\nid: 11111111-1111-1111-1111-111111111111\n---\n\n# Hello From The Vault\n\nBody text.",
            filename: "Hello.md",
            in: vault.rootURL
        )

        let binary = try locateBinary()
        let (process, stdinPipe, stdoutPipe) = try launch(binary: binary, arguments: [vault.rootURL.path])
        let client = Client(name: "punkrecords-mcp-smoke-test", version: "1.0.0")

        let initializeResult = try await client.connect(transport: makeTransport(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe))
        #expect(initializeResult.serverInfo.name == "punkrecords-mcp")

        let (tools, _) = try await client.listTools()
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames == ["vault_search", "read_document", "list_documents"])
        #expect(!toolNames.contains("create_note"), "create_note must stay hidden without --writable")

        let (content, isError) = try await client.callTool(name: "list_documents", arguments: [:])
        #expect(isError != true)
        guard case let .text(text, _, _)? = content.first else {
            Issue.record("expected text content in tools/call result, got \(content)")
            await shutdown(process: process, client: client)
            return
        }
        #expect(text.contains("Hello From The Vault"))

        await shutdown(process: process, client: client)
    }

    @Test("--writable exposes create_note, and it actually creates a file on disk")
    func writableModeCreatesNote() async throws {
        let factory = TempVaultFactory()
        let (vault, cleanup) = try factory.createTempVault(name: "MCPSmokeTestVaultWritable")
        defer { cleanup() }

        let binary = try locateBinary()
        let (process, stdinPipe, stdoutPipe) = try launch(binary: binary, arguments: [vault.rootURL.path, "--writable"])
        let client = Client(name: "punkrecords-mcp-smoke-test", version: "1.0.0")

        _ = try await client.connect(transport: makeTransport(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe))

        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name).contains("create_note"))

        let (content, isError) = try await client.callTool(
            name: "create_note",
            arguments: ["title": "Smoke Test Note", "content": "Created by the MCP smoke test."]
        )
        #expect(isError != true)
        guard case let .text(text, _, _)? = content.first else {
            Issue.record("expected text content in tools/call result, got \(content)")
            await shutdown(process: process, client: client)
            return
        }
        #expect(text.contains("Smoke Test Note"))

        let created = vault.rootURL.appendingPathComponent("Smoke Test Note.md")
        #expect(FileManager.default.fileExists(atPath: created.path))

        await shutdown(process: process, client: client)
    }
}
