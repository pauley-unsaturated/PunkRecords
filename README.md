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

- **macOS 15** (Sequoia) or later
- **Xcode 16** or later
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — used to generate the Xcode project from `project.yml`

## Building

1. Install XcodeGen if you don't have it:

   ```sh
   brew install xcodegen
   ```

2. Generate the Xcode project:

   ```sh
   xcodegen generate
   ```

3. Open and build in Xcode:

   ```sh
   open PunkRecords.xcodeproj
   ```

   Or build from the command line:

   ```sh
   xcodebuild -scheme PunkRecords -configuration Debug build
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
│   └── PunkRecordsTestSupport/   # Mocks and test utilities
├── Tests/
│   ├── PunkRecordsIntegrationTests/
│   ├── PunkRecordsPromptEvals/   # LLM output quality evaluations
│   └── PunkRecordsUITests/
├── project.yml                   # XcodeGen project definition
└── SPEC.md                       # Full product & technical specification
```

## Testing

Run all tests from Xcode (Cmd+U) or from the command line:

```sh
xcodebuild -scheme PunkRecords -configuration Debug test
```

The test suite includes:

- **Unit tests** in each package (`PunkRecordsCoreTests`, `PunkRecordsInfraTests`)
- **Integration tests** covering document lifecycle, context building, and search
- **Prompt evals** that validate LLM output structure and grounding
- **UI tests** for the editor and chat panel

## License

All rights reserved.
