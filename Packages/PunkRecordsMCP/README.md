# PunkRecordsMCP

A stdio [Model Context Protocol](https://modelcontextprotocol.io) server that exposes a
PunkRecords vault to any MCP-aware client — Claude Desktop, Claude Code, Cursor, etc. — as
four tools:

| MCP tool         | Backing `AgentTool`  | Availability          |
|-------------------|-----------------------|------------------------|
| `vault_search`    | `VaultSearchTool`     | always                |
| `read_document`   | `ReadDocumentTool`    | always                |
| `list_documents`  | `ListDocumentsTool`   | always                |
| `create_note`     | `CreateNoteTool`      | only with `--writable`|

This is intentionally a **thin wrapper**: the tools themselves already exist in
`PunkRecordsCore/Services/Tools/`; this package is protocol plumbing that adapts them to MCP's
`tools/list` + `tools/call` surface and wires them to a real on-disk vault via
`FileSystemDocumentRepository` + `SQLiteSearchIndex` (the same Infra services the app itself
uses).

**Not in scope:** `summarize_url` is not exposed. Its backing feature (web-content extraction)
is still under active development in other PunkRecords issues, so it was left out rather than
wrapping a half-finished tool.

## Build

```sh
cd Packages/PunkRecordsMCP
swift build
```

The binary lands at `Packages/PunkRecordsMCP/.build/<arch>-apple-macosx/debug/punkrecords-mcp`
(or run `swift build --show-bin-path` from this directory to print the exact path for your
toolchain/configuration). For a release build: `swift build -c release`
(`.build/<arch>-apple-macosx/release/punkrecords-mcp`).

This package is **not** wired into the main Xcode project (`project.yml`/`xcodegen`). The
official MCP Swift SDK pulls in SwiftNIO + AsyncHTTPClient transitively (for HTTP/SSE
transports this server doesn't use — only `StdioTransport` is used here), and keeping it a
separate `swift build` product keeps that dependency graph out of `xcodebuild -scheme
PunkRecords build` and the existing test suites entirely. See "SDK vs hand-rolled" below.

## Usage

```
punkrecords-mcp [vault-path] [options]

ARGUMENTS:
    vault-path            Path to the vault directory. Defaults to the current working
                           directory if omitted.

OPTIONS:
    --vault <path>         Same as the positional argument; takes precedence if both are given.
    --writable              Enable create_note. Omit this flag to run read-only.
    -h, --help              Print usage and exit.
    --version                Print the server version and exit.
```

Any directory can be a vault — same rule the app itself follows (see `AppState.openVault`);
there's no `.punkrecords` marker file requirement. On startup the server reads every `.md` file
under the vault root and rebuilds the FTS5 search index at `<vault>/.punkrecords/index.sqlite`
(the same derived-data path the app uses), so `vault_search` works immediately.

**Known limitation:** the server indexes once at startup and does not watch the filesystem for
changes afterward (unlike the app, which uses FSEvents to keep the index live). If you edit the
vault from elsewhere while `punkrecords-mcp` is running, restart it to pick up the changes.

## Claude Desktop setup

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "punkrecords": {
      "command": "/absolute/path/to/Packages/PunkRecordsMCP/.build/arm64-apple-macosx/debug/punkrecords-mcp",
      "args": ["--vault", "/absolute/path/to/your/vault"]
    }
  }
}
```

Add `"--writable"` to `args` to also allow note creation:

```json
{
  "mcpServers": {
    "punkrecords": {
      "command": "/absolute/path/to/Packages/PunkRecordsMCP/.build/arm64-apple-macosx/debug/punkrecords-mcp",
      "args": ["--vault", "/absolute/path/to/your/vault", "--writable"]
    }
  }
}
```

Restart Claude Desktop after editing the config.

## Claude Code setup

```sh
claude mcp add punkrecords -- /absolute/path/to/Packages/PunkRecordsMCP/.build/arm64-apple-macosx/debug/punkrecords-mcp --vault /absolute/path/to/your/vault
```

Add `--writable` on the end of that command to also allow note creation. Run `claude mcp list`
to confirm it's registered, and `/mcp` inside a Claude Code session to check connection status.

## SDK vs hand-rolled

PUNK-q9h's scope called for preferring the official
[modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) if it works
with this toolchain (Xcode 26 / Swift 6.3 strict concurrency), and hand-rolling a minimal
JSON-RPC 2.0 stdio loop otherwise. The official SDK (resolved to `0.12.1`) built cleanly against
this toolchain with no strict-concurrency errors and no workarounds needed, so it's used as-is —
`Server`/`Client` actors, `StdioTransport`, and the typed `Tool`/`Value`/`CallTool` wire types.
This buys spec correctness (framing, `initialize` handshake, capability negotiation, error
shapes) essentially for free, at the cost of the transitive SwiftNIO/AsyncHTTPClient dependency
noted above — judged an acceptable tradeoff for an isolated CLI package that never links into
the app.

## Package layout

- `Sources/PunkRecordsMCPKit/` — all real logic, as a library so it's testable (SPM executable
  targets can't be imported by test targets):
  - `CLIOptions.swift` — argument parsing (`CLIParser.parse`), pure.
  - `VaultResolver.swift` — vault path resolution from CLI args + injected cwd/filesystem
    checks, pure.
  - `WritableGate.swift` — the `--writable` gating logic (hides `create_note` from `tools/list`
    and rejects `tools/call` for it when read-only), pure.
  - `MCPToolAdapter.swift` — `AgentTool` &lt;-&gt; MCP wire type translation (schema, argument
    decoding, result encoding), pure.
  - `ServerFactory.swift` — wires `AgentTool`s to a `FileSystemDocumentRepository` +
    `SQLiteSearchIndex` and registers the MCP `Server`'s `tools/list`/`tools/call` handlers.
  - `Runner.swift` — the CLI entry point: parse → resolve vault → index → start server.
- `Sources/punkrecords-mcp/main.swift` — thin executable shim calling `Runner.run(arguments:)`.
- `Tests/PunkRecordsMCPKitTests/` — see "Tests" below.

## Tests

```sh
cd Packages/PunkRecordsMCP
swift test
```

- `CLIParserTests`, `VaultResolverTests`, `WritableGateTests`, `MCPToolAdapterTests` — pure-function
  unit tests over the adapter layer: schema conversion, argument decoding, result encoding, and
  `--writable` gating. Fast, no I/O, no subprocess.
- `EndToEndSmokeTests` — builds the real `punkrecords-mcp` binary, launches it as a subprocess
  against a throwaway vault (`PunkRecordsTestSupport.TempVaultFactory`), and speaks `initialize` +
  `tools/list` + `tools/call` to it over real stdin/stdout pipes using the same MCP `Client` a
  real host would use (confirming `create_note` is hidden by default and appears — and actually
  writes a file — with `--writable`). This is the most faithful test available, at the cost of
  being slower (it invokes `swift build` to guarantee the binary is current) and more
  environment-sensitive (requires `swift` on `PATH`) than an in-process test. The adapter unit
  tests above cover the same translation logic synchronously/in-process as a fast, non-flaky
  complement — if the subprocess test ever proves flaky in CI, that's the fallback this issue
  anticipated.
