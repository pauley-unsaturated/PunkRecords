# PunkRecords

A macOS-native personal knowledge base built on plain Markdown files with deep, first-class LLM integration.

Named after Dr. Vegapunk's Punk Records from *One Piece* — the giant externalized brain that stores all knowledge and lets satellite bodies sync to it. PunkRecords does the same for your mind: your knowledge lives in a vault of Markdown files, LLMs process and enhance it, and you direct the whole thing.

## What It Does

- **Plain Markdown storage.** Your notes are `.md` files in a folder you choose. No proprietary database, no lock-in.
- **LLM as author.** The AI doesn't just answer questions — it writes wiki articles, compiles sources, maintains links, and keeps the knowledge base healthy. Every interaction compounds.
- **Multi-provider LLM support.** On-device Apple Intelligence (macOS 26+), Anthropic Claude, and OpenAI — switchable per query.
- **Full-text search.** FTS5-powered search with BM25 ranking, wiki-link traversal, and backlink discovery.
- **Native Mac app.** SwiftUI + AppKit. Syntax-highlighted Markdown editor, sidebar vault browser, integrated AI chat panel.

## Requirements

- **macOS 26** (Tahoe) or later
- **Xcode 26** or later
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — used to generate the Xcode project from `project.yml`
- **[SwiftLint](https://github.com/realm/SwiftLint)** — style backstop, run before committing

## Building

1. Install XcodeGen and SwiftLint if you don't have them:

   ```sh
   brew install xcodegen
   brew install swiftlint
   ```

2. Generate the Xcode project:

   ```sh
   xcodegen generate
   ```

   `PunkRecords.xcodeproj` is generated, not checked in — re-run this command
   after changing `project.yml`/`Package.swift`, or after adding/removing
   files in an app or test target.

3. Open and build in Xcode:

   ```sh
   open PunkRecords.xcodeproj
   ```

   Or build from the command line. `-skipMacroValidation` is required:
   AnyLanguageModel ships Swift macros that otherwise abort non-interactive
   `xcodebuild` runs.

   ```sh
   xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation build
   ```

## Running

Launch the app from Xcode (Cmd+R) or from the build output. On first launch, open a folder to use as your vault — any directory of Markdown files works.

To use cloud LLM providers, add your API keys in Settings (Anthropic and/or OpenAI).

## Project Structure

```
PunkRecords/
├── Sources/PunkRecordsApp/       # App target — views, view models, app entry point
├── Packages/
│   ├── PunkRecordsCore/          # Domain models, protocols, and pure-logic services
│   ├── PunkRecordsInfra/         # Concrete implementations — file I/O, SQLite, LLM providers
│   ├── PunkRecordsTestSupport/   # Mocks and test utilities
│   └── PunkRecordsEvals/         # Agent eval framework (scripted model, prompt logging)
├── Tests/
│   ├── PunkRecordsIntegrationTests/
│   ├── PunkRecordsPromptEvals/   # LLM output quality evaluations
│   ├── PunkRecordsEvalTests/     # Agent task-completion & context-threading evals
│   └── PunkRecordsUITests/
├── project.yml                   # XcodeGen project definition
└── SPEC.md                       # Full product & technical specification
```

## Testing

Run all tests from Xcode (Cmd+U) or from the command line:

```sh
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test
```

Run a single test bundle with `-only-testing:`, e.g.:

```sh
xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsIntegrationTests
```

The test suite includes:

- **Unit tests** in each package (`PunkRecordsCoreTests`, `PunkRecordsInfraTests`)
- **Integration tests** covering document lifecycle, context building, and search
- **Prompt evals** that validate LLM output structure and grounding (need an API key; excluded from the default test plan)
- **Agent evals** covering task completion, context threading, and token efficiency — deterministic by default, scripting the model through the real agent runner
- **UI tests** for the editor and chat panel

Live LLM evals (real API calls, real cost — in the Prompt evals and Agent
evals suites) are opt-in via `PUNKRECORDS_LIVE_EVALS=1`. Under `xcodebuild`,
environment variables must be prefixed `TEST_RUNNER_` to reach the test
process — a plain env var never reaches it, and the suite silently reports
"Executed 0 tests":

```sh
TEST_RUNNER_PUNKRECORDS_LIVE_EVALS=1 xcodebuild -scheme PunkRecords -configuration Debug -skipMacroValidation test -only-testing:PunkRecordsEvalTests/LiveSessionAgentEvals
```

## Linting

Run SwiftLint before committing as a style backstop:

```sh
swiftlint
swiftlint --strict   # treats warnings as errors
```

## License

All rights reserved.
