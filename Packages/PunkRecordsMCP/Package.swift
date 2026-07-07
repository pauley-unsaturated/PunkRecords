// swift-tools-version: 6.0
import PackageDescription

// PunkRecordsMCP — a standalone stdio MCP server binary (`punkrecords-mcp`)
// exposing the Core AgentTools (VaultSearchTool, ReadDocumentTool,
// CreateNoteTool, ListDocumentsTool) to MCP-aware clients (Claude Desktop,
// Claude Code, Cursor). See README.md for setup + design notes.
//
// Deliberately NOT wired into project.yml/xcodegen: this package pulls in the
// official MCP Swift SDK, which transitively drags SwiftNIO + AsyncHTTPClient
// (needed for the SDK's HTTP/SSE transports, unused here — we only use
// StdioTransport). Keeping it a separate `swift build` product isolates that
// dependency graph from the main app's xcodebuild scheme so
// `xcodebuild -scheme PunkRecords build` and the existing test suites are
// unaffected. Build with `swift build` from this directory; see README.md.
let package = Package(
    name: "PunkRecordsMCP",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "punkrecords-mcp", targets: ["punkrecords-mcp"]),
    ],
    dependencies: [
        .package(path: "../PunkRecordsCore"),
        .package(path: "../PunkRecordsInfra"),
        .package(path: "../PunkRecordsTestSupport"),
        // Official Swift SDK for the Model Context Protocol. Used only for its
        // `Server`/`Client` actors + `StdioTransport` — see README.md "SDK vs
        // hand-rolled" for why this was chosen over a hand-rolled JSON-RPC loop.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        // Pure-ish library: CLI parsing, vault resolution, AgentTool <-> MCP
        // schema/argument/result adapters, and the server wiring. The
        // executable target below is a thin `main.swift` shim over this so the
        // logic stays unit-testable (SPM executable targets can't be imported
        // by test targets).
        .target(
            name: "PunkRecordsMCPKit",
            dependencies: [
                .product(name: "PunkRecordsCore", package: "PunkRecordsCore"),
                .product(name: "PunkRecordsInfra", package: "PunkRecordsInfra"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "punkrecords-mcp",
            dependencies: ["PunkRecordsMCPKit"]
        ),
        .testTarget(
            name: "PunkRecordsMCPKitTests",
            dependencies: [
                "PunkRecordsMCPKit",
                // Not imported (executable targets have nothing importable) —
                // listed so `swift test`'s build graph builds the real binary
                // before tests run. EndToEndSmokeTests spawns it directly by
                // locating it in the shared build products directory. This
                // avoids shelling out to a nested `swift build` from inside a
                // test, which deadlocks: the outer `swift test` process holds
                // this package's `.build` lock for its whole run, and a
                // spawned `swift build` on the same package blocks forever
                // waiting for that same lock.
                "punkrecords-mcp",
                .product(name: "PunkRecordsCore", package: "PunkRecordsCore"),
                .product(name: "PunkRecordsTestSupport", package: "PunkRecordsTestSupport"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
