# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```sh
# Generate Xcode project (required after changing project.yml, Package.swift
# files, or adding/removing files in app/test targets)
xcodegen generate

# Build from command line (-skipMacroValidation is REQUIRED: AnyLanguageModel
# ships Swift macros that otherwise abort non-interactive xcodebuild runs)
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation build

# Run all tests (integration + evals + UI tests)
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test

# Run a single test bundle
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsIntegrationTests
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsPromptEvals
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsUITests
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsEvalTests

# Run a single test class or method
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsIntegrationTests/ContextBuilderTests/testSmallTier

# Live LLM evals (real API calls, real cost) are opt-in via env flag. Under
# xcodebuild the TEST_RUNNER_ prefix is REQUIRED — plain env vars never reach
# the test process and the suites silently skip ("Executed 0 tests"):
TEST_RUNNER_PUNKRECORDS_LIVE_EVALS=1 xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsEvalTests/LiveSessionAgentEvals

# Live evals against a real on-disk vault (ALWAYS a disposable copy — create_note writes):
TEST_RUNNER_PUNKRECORDS_LIVE_EVALS=1 TEST_RUNNER_PUNKRECORDS_EVAL_VAULT=/path/to/vault-copy xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsEvalTests/LiveMusicDSPEvals

# Lint (style backstop) — run before committing; --strict turns warnings into errors
swiftlint
swiftlint --strict

# Architecture-boundary check (offline, no build) — fails if Core imports
# Infra/App/FoundationModels/AnyLanguageModel, if Infra imports App, or if
# Core's Package.swift declares a dependency on Infra/AnyLanguageModel
scripts/check-architecture.sh
```

Requires **Xcode 26+**, **XcodeGen** (`brew install xcodegen`), **SwiftLint** (`brew install swiftlint`), **macOS 26+** (deployment target — keep it at the OS/SDK actually installed; a higher target makes every test bundle unrunnable locally).

## Testing & Validation Discipline

Automated coverage is strong for pure logic but historically absent for the
SwiftUI/AppKit layer. To keep that gap from growing, follow this order:

1. **(Default, do this every feature) Lift logic out of views.** When building
   anything in a SwiftUI view or `NSTextView`/AppKit wiring, pull the decision,
   transformation, or parsing into a **pure function** in Core (or Infra if it
   needs AppKit) and unit-test *that*. The view becomes a thin shell that calls
   tested logic. Established examples to mirror: `TagAutocomplete`,
   `WikilinkAutocomplete`, `PreviewLinkRewriter`, `SidebarFilter`,
   `QuickOpenMatcher`, `TreeSitterMarkdownHighlighter.codeHighlightSpans`.
   Before closing an issue, ask: "what part of this could be a pure function,
   and did I test it?"

2. **(Backstop, after #1) XCUITest the golden path.** For critical end-to-end
   interactions (e.g. type `#` → popover → accept; preview link → navigation),
   add a test to `PunkRecordsUITests`. Higher fidelity but slower/flakier, so
   reserve it for a few load-bearing flows rather than everything.

3. **(Explicitly manual) Pure-visual checks.** Theme colors, popover placement,
   and rendering appearance have poor automation ROI — validate by hand and say
   so in the issue's close reason so it's clear what was *not* automated.

Run `swiftlint` before every commit as a style backstop (see Build Commands).

## Architecture

Three-layer clean architecture with strict dependency direction:

```
App Layer (Sources/PunkRecordsApp/)     — SwiftUI views, view models, app entry
    ↓
Core Layer (Packages/PunkRecordsCore/)  — Models, protocols, pure-logic services
    ↓
Infra Layer (Packages/PunkRecordsInfra/) — File I/O, SQLite, LLM API clients
```

- **Core** defines protocols (`DocumentRepository`, `SearchService`, `TextCompleter`, `AgentTool`); **Infra** provides concrete implementations.
- **App** depends on both Core and Infra. Core never imports Infra or App — in particular, Core never names FoundationModels/AnyLanguageModel.

### LLM Integration (session path)

All AI features ride ONE pipeline, backed by Hugging Face's
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) (a
FoundationModels-style `LanguageModel`/`LanguageModelSession` abstraction):

```
LLMChatPanel / DeferredSessionTextCompleter
    → LanguageModelFactory.makeModel(LLMProviderID)   [Infra]
    → SessionAgentRunner (round loop, context threading, AgentEvents)  [Infra]
    → LanguageModelSession + FoundationModelsToolAdapter → Core AgentTools
```

Provider mapping (`LLMProviderID` → backend): `.foundationModels` → ALM
`SystemLanguageModel` (Apple Intelligence on-device), `.anthropic` →
`AnthropicLanguageModel`, `.openAI` → `OpenAILanguageModel` (custom base URL
supported), `.anyLanguageModel` → `OllamaLanguageModel` (local).

Two load-bearing `SessionAgentRunner` invariants (guarded by
`SessionContextThreadingEvals`):
- It folds instructions + accumulated tool results into EVERY round's prompt
  (stateless backends like Ollama drop session instructions/history).
- It creates a FRESH `LanguageModelSession` per round and passes no
  `instructions:` — a reused session/empty instructions serialize empty text
  blocks that Anthropic's API rejects with 400.

### Concurrency Model

- All service interfaces are **actors** (repository, search index, session agent runner, context builder, note compiler).
- **Swift 6 strict concurrency** — all cross-isolation types must be `Sendable`.
- Reactive updates via `AsyncStream<VaultChange>` from the document repository.
- View models use `@Observable` on `@MainActor`.

### Key Services

| Service | Layer | Role |
|---------|-------|------|
| `MarkdownParser` | Core | Frontmatter, wikilinks, tags, title extraction |
| `ContextBuilder` | Core | Assembles document excerpts within token budget (3 tiers by context window size); `buildInstructions` emits the session system prompt |
| `NoteCompiler` | Core | Converts LLM responses into wiki articles via the `TextCompleter` seam |
| `TokenEstimator` | Core | Heuristic tokenizer (1 token ~ 4 chars); also backs session usage estimates |
| `VaultSearchTool` / `ReadDocumentTool` / `CreateNoteTool` / `ListDocumentsTool` | Core | Agent tools wrapping repository and search |
| `FileSystemDocumentRepository` | Infra | .md file CRUD + FSEvents file watching |
| `SQLiteSearchIndex` | Infra | FTS5 search with BM25, backlink tracking |
| `LanguageModelFactory` | Infra | `LLMProviderID` → AnyLanguageModel backend + availability probing; UI-test scripted hook |
| `SessionAgentRunner` | Infra | Agentic round loop over `LanguageModelSession`; emits `AgentEvent`s incl. estimated token usage |
| `SessionTextCompleter` / `DeferredSessionTextCompleter` | Infra | `TextCompleter` over the session path; deferred variant resolves provider/config per call |
| `ScriptedLanguageModel` | Infra | Deterministic scripted backend for evals and `--ui-testing-scripted-chat` |

### Data Storage

- Documents are plain `.md` files with YAML frontmatter (id, tags, created, modified).
- Search index lives at `.punkrecords/index.sqlite` inside the vault — derived data, rebuilt on vault open.
- API keys stored in macOS Keychain via `KeychainService`.

### Image attachment convention

Images authored into notes (pasted, dragged, or screenshot-captured) live at:

```
{vault}/attachments/{note-stem}/{filename}
```

where `{note-stem}` mirrors the note's relative path with the `.md` extension removed. An image attached to `Daily/2026-05-18.md` lives at `attachments/Daily/2026-05-18/foo.png`.

- Markdown references use vault-relative paths: `![alt](attachments/Daily/2026-05-18/foo.png)`. No leading slash, no `file://`.
- Filename collisions within a single note's attachments dir get an 8-character UUID suffix on the stem: `foo.png` → `foo-a1b2c3d4.png`.
- Spaces in paths are percent-encoded in markdown references for parser compatibility.
- Canonical implementation: `VaultPaths` in Core/Utilities. Use it from every write path that creates an attachment.

### Test Organization

- **Unit tests** live inside each package (`PunkRecordsCoreTests`, `PunkRecordsInfraTests`).
- **Integration tests** (`Tests/PunkRecordsIntegrationTests/`) — document lifecycle, context building, search.
- **Prompt evals** (`Tests/PunkRecordsPromptEvals/`) — validate LLM output structure and grounding quality on the session path. Live tests need an API key AND `PUNKRECORDS_LIVE_EVALS=1`.
- **Agent evals** (`Tests/PunkRecordsEvalTests/`) — task completion, context threading, token efficiency, flywheel A/B. Deterministic runs script the model with `ScriptedLanguageModel` (round-structured via `.endTurn`; `PromptLog` records per-round prompts) through the REAL `SessionAgentRunner`. Live suites are opt-in via `PUNKRECORDS_LIVE_EVALS=1`. Eval framework lives in `Packages/PunkRecordsEvals/`.
- **UI tests** (`Tests/PunkRecordsUITests/`) — editor and chat panel interactions. `ChatTurnUITests` drives a full chat turn (send → tool chip → assistant bubble) against the scripted model via the `--ui-testing-scripted-chat` launch flag; requires an interactive session with automation permission granted.
- **Test support** (`Packages/PunkRecordsTestSupport/`) — mocks for `DocumentRepository`, `SearchService`, `MockTextCompleter`; `TempVaultFactory` for isolated test vaults.

### Multi-Window App Structure

The app uses SwiftUI multi-window architecture:
- **Welcome window** (CMD+0) — vault selection/creation via `RecentVaultsStore`.
- **Vault windows** — one `AppState` per open vault, initialized lazily with all dependencies.
- `AppState` is the central `@Observable` container: owns repository, search index, orchestrator, and note compiler.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
