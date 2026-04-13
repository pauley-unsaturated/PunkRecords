# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```sh
# Generate Xcode project (required after changing project.yml or Package.swift files)
xcodegen generate

# Build from command line
xcodebuild -scheme PunkRecords -configuration Debug build

# Run all tests (integration + prompt evals + UI tests)
xcodebuild -scheme PunkRecords -configuration Debug test

# Run a single test bundle
xcodebuild -scheme PunkRecords -configuration Debug test -only-testing:PunkRecordsIntegrationTests
xcodebuild -scheme PunkRecords -configuration Debug test -only-testing:PunkRecordsPromptEvals
xcodebuild -scheme PunkRecords -configuration Debug test -only-testing:PunkRecordsUITests
xcodebuild -scheme PunkRecords -configuration Debug test -only-testing:PunkRecordsEvalTests

# Run a single test class or method
xcodebuild -scheme PunkRecords -configuration Debug test -only-testing:PunkRecordsIntegrationTests/ContextBuilderTests/testSmallTier
```

Requires **Xcode 16+**, **XcodeGen** (`brew install xcodegen`), macOS 15+.

## Architecture

Three-layer clean architecture with strict dependency direction:

```
App Layer (Sources/PunkRecordsApp/)     — SwiftUI views, view models, app entry
    ↓
Core Layer (Packages/PunkRecordsCore/)  — Models, protocols, pure-logic services
    ↓
Infra Layer (Packages/PunkRecordsInfra/) — File I/O, SQLite, LLM API clients
```

- **Core** defines protocols (`DocumentRepository`, `LLMProvider`, `SearchService`); **Infra** provides concrete implementations.
- **App** depends on both Core and Infra. Core never imports Infra or App.

### Concurrency Model

- All service interfaces are **actors** (repository, search index, orchestrator, context builder, note compiler).
- **Swift 6 strict concurrency** — all cross-isolation types must be `Sendable`.
- Reactive updates via `AsyncStream<VaultChange>` from the document repository.
- View models use `@Observable` on `@MainActor`.

### Key Services

| Service | Layer | Role |
|---------|-------|------|
| `MarkdownParser` | Core | Frontmatter, wikilinks, tags, title extraction |
| `LLMOrchestrator` | Core | Routes queries to providers, manages fallback |
| `ContextBuilder` | Core | Assembles document excerpts within token budget (3 tiers by context window size) |
| `NoteCompiler` | Core | Converts LLM responses into wiki articles with proper frontmatter/links |
| `TokenEstimator` | Core | Heuristic tokenizer (1 token ~ 4 chars) |
| `FileSystemDocumentRepository` | Infra | .md file CRUD + FSEvents file watching |
| `SQLiteSearchIndex` | Infra | FTS5 search with BM25, backlink tracking |
| `AgentLoop` | Core | Iterative tool-call loop: LLM → tool execution → repeat |
| `VaultSearchTool` / `ReadDocumentTool` / `CreateNoteTool` / `ListDocumentsTool` | Core | Agent tools wrapping repository and search |
| `AnthropicProvider` / `OpenAIProvider` / `FoundationModelsProvider` | Infra | LLM API clients (Anthropic has prompt caching + tool use) |

### Data Storage

- Documents are plain `.md` files with YAML frontmatter (id, tags, created, modified).
- Search index lives at `.punkrecords/index.sqlite` inside the vault — derived data, rebuilt on vault open.
- API keys stored in macOS Keychain via `KeychainService`.

### Test Organization

- **Unit tests** live inside each package (`PunkRecordsCoreTests`, `PunkRecordsInfraTests`).
- **Integration tests** (`Tests/PunkRecordsIntegrationTests/`) — document lifecycle, context building, search, orchestrator routing.
- **Prompt evals** (`Tests/PunkRecordsPromptEvals/`) — validate LLM output structure and grounding quality (tagged `.eval`, requires API key).
- **Agent evals** (`Tests/PunkRecordsEvalTests/`) — task completion, context builder quality, token efficiency. Uses `ScriptedProvider` for deterministic mock runs. Eval framework lives in `Packages/PunkRecordsEvals/`.
- **UI tests** (`Tests/PunkRecordsUITests/`) — editor and chat panel interactions.
- **Test support** (`Packages/PunkRecordsTestSupport/`) — mocks for `DocumentRepository`, `SearchService`, `LLMProvider`; `TempVaultFactory` for isolated test vaults.

### Multi-Window App Structure

The app uses SwiftUI multi-window architecture:
- **Welcome window** (CMD+0) — vault selection/creation via `RecentVaultsStore`.
- **Vault windows** — one `AppState` per open vault, initialized lazily with all dependencies.
- `AppState` is the central `@Observable` container: owns repository, search index, orchestrator, and note compiler.
