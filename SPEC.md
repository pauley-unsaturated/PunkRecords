# PunkRecords — Product & Technical Specification

> *"The Poneglyphs recorded history the world tried to erase. PunkRecords does the same for your mind."*

**Version:** 0.1 (Pre-build)
**Status:** Draft — iterate before building
**Platform:** macOS (primary), iOS / visionOS (future phases)

---

## Table of Contents

1. [Vision & Goals](#1-vision--goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Module Breakdown](#3-module-breakdown)
4. [Data Model](#4-data-model)
5. [Document Storage & iCloud Sync](#5-document-storage--icloud-sync)
6. [Markdown Editor Design](#6-markdown-editor-design)
7. [LLM Integration Layer](#7-llm-integration-layer)
8. [Search Architecture](#8-search-architecture)
9. [Testing Strategy](#9-testing-strategy)
10. [Phase Breakdown](#10-phase-breakdown)
11. [Open Questions & Decisions](#11-open-questions--decisions)

---

## 1. Vision & Goals

### What It Is

PunkRecords is a macOS-first personal knowledge base built on plain Markdown files, differentiated by deep, first-class LLM integration. It stores your notes, research, PDFs, and ideas in iCloud Drive — fully portable, fully yours — while giving you an on-device AI assistant that understands your entire knowledge base.

Think Obsidian meets Apple Intelligence, with escape hatches to Anthropic and OpenAI when you need more horsepower.

### Core Principles

- **Your files, your format.** Notes are `.md` files on disk. No proprietary database. No lock-in.
- **Privacy first.** Default inference is on-device via Apple FoundationModels. Cloud models are opt-in.
- **Deep, not wide.** The LLM doesn't just answer questions — it cross-references your KB, finds contradictions, surfaces related notes, and acts as a research librarian.
- **Native Mac.** SwiftUI + AppKit. Feels like a real Mac app, not an Electron wrapper.

### Non-Goals (v1)

- Real-time collaboration
- Mobile-first or web app
- Vector database / semantic search (Phase 3+)
- PDF editing (view only)
- Custom plugin system

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        PunkRecords.app                          │
│                                                                 │
│  ┌──────────────┐  ┌────────────────┐  ┌─────────────────────┐ │
│  │  UI Layer    │  │  Domain Layer  │  │  Infrastructure     │ │
│  │  (SwiftUI /  │  │  (Pure Swift)  │  │  Layer              │ │
│  │   AppKit)    │  │                │  │                     │ │
│  │              │  │  • Document    │  │  • FileSystemStore  │ │
│  │  • Editor    │  │    Service     │  │  • iCloudSync       │ │
│  │  • Sidebar   │  │  • Search      │  │  • LLMProviders     │ │
│  │  • Preview   │  │    Service     │  │    (Foundation,     │ │
│  │  • LLM Chat  │  │  • LLM         │  │     Anthropic,      │ │
│  │  • Settings  │  │    Orchestrator│  │     OpenAI, MLX)    │ │
│  └──────────────┘  └────────────────┘  └─────────────────────┘ │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   Persistence Layer                       │  │
│  │   iCloud Drive (.md files)  ·  SQLite (index/metadata)   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Layering Rules

- **UI Layer** knows about ViewModels, never directly about infrastructure.
- **Domain Layer** defines protocols. It has no imports of UIKit, AppKit, or any third-party SDK.
- **Infrastructure Layer** implements domain protocols. It's the only place with filesystem, network, or ML framework calls.
- All cross-layer communication uses protocols defined in the Domain Layer. This makes every layer independently testable.

### Key Design Patterns

- **MVVM** for UI/ViewModel binding (SwiftUI-native with `@Observable`)
- **Repository pattern** for document and index access
- **Strategy pattern** for LLM provider selection
- **Actor isolation** for all async document I/O and LLM calls
- **Structured concurrency** (`async/await`, `AsyncSequence` for streaming responses)

---

## 3. Module Breakdown

### 3.1 `PunkRecordsCore` (Swift Package, no UI dependencies)

The heart of the app. Depends only on Foundation and Swift standard library.

| Component | Responsibility |
|---|---|
| `Document` | Value type representing a single note |
| `Vault` | Collection of documents with metadata |
| `DocumentRepository` (protocol) | CRUD + watch for changes |
| `SearchService` (protocol) | Full-text and LLM-assisted search |
| `LLMOrchestrator` | Routes queries to appropriate provider, manages context window |
| `LLMProvider` (protocol) | Abstraction over all inference backends |
| `ContextBuilder` | Assembles relevant document excerpts into LLM context |
| `MarkdownParser` | Parses `.md` to AST; extracts links, tags, frontmatter |

### 3.2 `PunkRecordsInfra` (Swift Package)

Concrete implementations. Imports FoundationModels, MLX, network SDKs.

| Component | Responsibility |
|---|---|
| `FileSystemDocumentRepository` | Reads/writes `.md` files; watches via `FSEventStream` |
| `iCloudSyncCoordinator` | Manages `NSFileCoordinator`, conflict resolution |
| `SQLiteSearchIndex` | Full-text search via FTS5; metadata indexing |
| `FoundationModelsProvider` | Apple on-device inference via FoundationModels framework |
| `MLXProvider` | Local model inference via MLX-Swift |
| `AnthropicProvider` | Anthropic Messages API client |
| `OpenAIProvider` | OpenAI Chat Completions API client |
| `PDFRenderer` | Wraps PDFKit for in-app PDF viewing |

### 3.3 `PunkRecordsUI` (App target)

SwiftUI views and AppKit integration.

| Component | Responsibility |
|---|---|
| `VaultBrowserView` | Sidebar: folder/file tree |
| `EditorView` | Split preview+raw or full-preview WYSIWYG |
| `MarkdownRenderer` | Live-rendered GFM view (read/preview mode) |
| `RawEditorView` | Syntax-highlighted raw text editor |
| `LLMChatPanel` | Slide-in panel for KB-aware AI chat |
| `TextSelectionMenu` | Contextual menu on selected text: "Ask AI", "Find related" |
| `SearchView` | Full-text + LLM-assisted search UI |
| `SettingsView` | API keys, model selection, sync preferences |
| `PDFViewerView` | Embedded PDF viewer (PDFKit) |

### 3.4 Supporting Packages

- **`MarkdownAST`** — shared AST types used by both parser and renderer; no UI or I/O deps
- **`PunkRecordsTestSupport`** — mock implementations of domain protocols for use in tests

---

## 4. Data Model

### 4.1 `Document`

```swift
struct Document: Identifiable, Hashable, Sendable {
    let id: DocumentID          // Stable UUID, stored in frontmatter
    var title: String           // Derived from H1 or filename
    var content: String         // Raw markdown string
    var path: RelativePath      // Relative to vault root
    var tags: [String]          // Parsed from frontmatter `tags:`
    var created: Date
    var modified: Date
    var frontmatter: [String: String]  // Raw YAML frontmatter key/values
    var linkedDocumentIDs: [DocumentID] // Parsed [[wikilink]] and [text](path) references
}

typealias DocumentID = UUID
typealias RelativePath = String
```

### 4.2 `Vault`

```swift
struct Vault: Identifiable, Sendable {
    let id: UUID
    var name: String
    var rootURL: URL            // iCloud Drive container directory
    var settings: VaultSettings
}

struct VaultSettings: Codable, Sendable {
    var defaultLLMProvider: LLMProviderID
    var enabledProviders: [LLMProviderID]
    var ignoredPaths: [String]  // glob patterns (e.g., ".obsidian/**")
    var autoIndexOnSave: Bool
}
```

### 4.3 Search Index (SQLite)

Stored at `<vault_root>/.punkrecords/index.sqlite`. Three tables:

```sql
-- Full-text search via FTS5
CREATE VIRTUAL TABLE document_fts USING fts5(
    id UNINDEXED,
    title,
    body,
    tags,
    tokenize = 'porter ascii'
);

-- Document metadata (fast lookups without reading .md files)
CREATE TABLE document_meta (
    id          TEXT PRIMARY KEY,   -- UUID string
    path        TEXT NOT NULL,
    title       TEXT,
    created_at  INTEGER NOT NULL,   -- Unix timestamp
    modified_at INTEGER NOT NULL,
    tag_json    TEXT                -- JSON array of tags
);

-- Wiki-style links for graph/backlinks
CREATE TABLE document_links (
    source_id   TEXT NOT NULL,
    target_id   TEXT,               -- NULL if target not yet resolved
    target_path TEXT,
    link_text   TEXT
);
```

### 4.4 LLM Context

```swift
struct LLMRequest: Sendable {
    var userPrompt: String
    var systemPrompt: String?
    var contextDocuments: [DocumentExcerpt]   // Relevant KB snippets
    var selectedText: String?                  // If user selected text
    var streamResponse: Bool
}

struct DocumentExcerpt: Sendable {
    let documentID: DocumentID
    let title: String
    let excerpt: String     // Trimmed to fit context window budget
    let relevanceScore: Float
}

struct LLMResponse: Sendable {
    let text: String
    let providerID: LLMProviderID
    let usedDocuments: [DocumentID]  // Which KB docs were referenced
    let usage: TokenUsage?
}
```

### 4.5 Frontmatter Convention

PunkRecords adds a minimal set of frontmatter fields on document creation. All fields are optional — documents without frontmatter are fully supported.

```yaml
---
id: 550e8400-e29b-41d4-a716-446655440000
created: 2026-04-05T12:00:00Z
modified: 2026-04-05T14:30:00Z
tags: [research, ai, swift]
---
```

---

## 5. Document Storage & iCloud Sync

### 5.1 Storage Layout

```
iCloud Drive/
└── PunkRecords/                    ← App's iCloud container
    └── <VaultName>/
        ├── .punkrecords/
        │   ├── index.sqlite        ← Search index (not synced, regenerated)
        │   ├── vault.json          ← Vault settings
        │   └── .noindex            ← Tells Spotlight to skip index files
        ├── Notes/
        │   ├── MyNote.md
        │   └── Subfolder/
        │       └── AnotherNote.md
        └── Attachments/
            └── paper.pdf
```

The `.punkrecords/` directory is excluded from iCloud sync via `URLResourceKey.isExcludedFromBackupKey` on the index file. The `index.sqlite` is always regenerated locally from the synced `.md` files.

### 5.2 File Watching

- Use `FSEventStream` (via `FileSystemDocumentRepository`) to watch the vault root directory tree.
- On file events: debounce 300ms, re-read changed files, update SQLite index, publish changes to UI via `AsyncStream<VaultChange>`.
- `NSFileCoordinator` wraps all reads and writes to be iCloud-safe.
- `NSFilePresenter` protocol handles iCloud-initiated changes (another device saving a file).

### 5.3 Conflict Resolution

iCloud Drive uses a "last write wins" model with conflict versions surfaced as shadow files (`filename (conflicted copy ...).md`). PunkRecords will:

1. Detect conflicted copies in `FSEventStream` callbacks.
2. Surface a conflict resolution UI showing a diff.
3. Let the user pick a version or manually merge.
4. Archive the rejected version to `.punkrecords/conflicts/` before deleting.

**Phase 1 simplification:** Show a banner "Conflict detected in Note X" with a button to open both versions side-by-side. Full merge UI is Phase 2.

### 5.4 New Vault Creation

1. User picks a name.
2. App creates directory in iCloud Drive container.
3. Writes `vault.json` with default settings.
4. Performs initial full index build.
5. Adds vault to app's `VaultRegistry` (stored in UserDefaults / App Group container).

---

## 6. Markdown Editor Design

### 6.1 Two Modes

**Preview Mode (default)**

- Renders GitHub-Flavored Markdown (GFM) live as the user types.
- Editing happens inline — click to place cursor, type to modify the underlying Markdown source.
- Implemented as a custom `NSTextView` subclass (`PRTextView`) with:
  - A `MarkdownTypingTransformer` that converts typed Markdown syntax to styled attributed text in real time (e.g., typing `**` around a word bolds it).
  - A `MarkdownAttributedStringRenderer` that converts the AST to `NSAttributedString`.
- The raw Markdown is always the source of truth. The styled view is a presentation layer.
- Supports GFM: headers, bold, italic, strikethrough, inline code, fenced code blocks, blockquotes, ordered/unordered lists, task lists, tables, horizontal rules.

**Raw Mode**

- Plain text editor showing the raw `.md` source.
- Syntax highlighting via `NSTextStorage` + regex-based highlighter (no Tree-sitter in Phase 1).
- Toggle between modes: `⌘⇧P` (matching muscle memory from other editors).
- The two modes share the same underlying `DocumentEditorViewModel` — switching modes is a view-layer concern only.

### 6.2 PDF Embedding

Markdown link syntax: `[Description](attachments/paper.pdf)`

- When the renderer encounters a link to a `.pdf` file:
  - Renders an inline "PDF card" showing filename + page count.
  - Click opens an embedded `PDFView` (PDFKit) in a split pane below the note, or in a separate sheet.
- No PDF editing. Annotation support is a future phase.

### 6.3 Wikilinks

`[[Note Title]]` or `[[Note Title|Display Text]]`

- Rendered as tappable links. Clicking navigates to the target note.
- Unresolved wikilinks shown in a distinct style (e.g., dashed underline).
- On save, `linkedDocumentIDs` in the document model is updated for backlink tracking.

### 6.4 Editor State

```swift
@Observable
final class DocumentEditorViewModel {
    var document: Document
    var editorMode: EditorMode     // .preview, .raw
    var isDirty: Bool
    var selectionRange: NSRange?
    var isSaving: Bool

    func save() async throws
    func toggleMode()
    func applyLLMSuggestion(_ text: String, at range: NSRange) async
}

enum EditorMode { case preview, raw }
```

### 6.5 Autosave

- Debounced autosave: 2 seconds after last keystroke.
- Manual save: `⌘S` (immediate).
- Dirty indicator in window title (`•` prefix, standard macOS convention).
- Autosave writes through `DocumentRepository`, which calls `NSFileCoordinator` for iCloud safety.

---

## 7. LLM Integration Layer

### 7.1 Provider Abstraction

All inference goes through a single protocol:

```swift
protocol LLMProvider: Actor {
    var id: LLMProviderID { get }
    var displayName: String { get }
    var capabilities: LLMCapabilities { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
    func isAvailable() async -> Bool
}

struct LLMCapabilities: OptionSet {
    static let streaming     = LLMCapabilities(rawValue: 1 << 0)
    static let functionCalls = LLMCapabilities(rawValue: 1 << 1)
    static let longContext   = LLMCapabilities(rawValue: 1 << 2)  // >32k tokens
    static let onDevice      = LLMCapabilities(rawValue: 1 << 3)
}

enum LLMProviderID: String, Codable {
    case foundationModels = "apple.foundation-models"
    case mlx              = "local.mlx"
    case anthropic        = "anthropic"
    case openAI           = "openai"
}
```

### 7.2 Provider Implementations

**`FoundationModelsProvider`**

- Uses Apple's `FoundationModels` framework (iOS 26 / macOS 26+).
- Requires Apple Intelligence to be enabled on device.
- Falls back gracefully if unavailable (e.g., older hardware).
- Privacy: no data leaves the device; eligible for Private Cloud Compute for larger requests.
- System prompt injection happens via the framework's structured generation APIs.

**`MLXProvider`**

- Uses `mlx-swift` to run quantized GGUF/MLX format models.
- Models stored in `~/Library/Application Support/PunkRecords/Models/`.
- Model management UI (download, delete, set active) in Settings.
- Runs on Apple Silicon GPU via Metal.
- Suitable for: Llama 3, Mistral, Phi-3, Qwen families.

**`AnthropicProvider`**

- Calls the Anthropic Messages API (`/v1/messages`).
- API key stored in macOS Keychain (never in UserDefaults or files).
- Supports streaming via SSE.
- Default model: `claude-opus-4-6` (configurable).
- Handles rate limits with exponential backoff.

**`OpenAIProvider`**

- Calls OpenAI Chat Completions API (`/v1/chat/completions`).
- API key stored in Keychain.
- Supports streaming.
- Default model: `gpt-4o` (configurable).
- Also supports OpenAI-compatible endpoints (Ollama, LM Studio) via custom base URL setting.

### 7.3 `LLMOrchestrator`

The orchestrator sits above the providers and manages:

1. **Provider selection** — default provider from settings; user can switch per-request.
2. **Context assembly** — calls `ContextBuilder` to find and rank relevant KB documents.
3. **Token budget management** — trims context to fit within provider's context window.
4. **Request routing** — if on-device provider unavailable, falls back to cloud (opt-in setting).
5. **Response streaming** — wraps provider streams into a unified `AsyncThrowingStream<LLMStreamEvent, Error>`.

```swift
actor LLMOrchestrator {
    func ask(
        prompt: String,
        selectedText: String? = nil,
        scope: QueryScope,
        provider: LLMProviderID? = nil  // nil = use default
    ) async throws -> AsyncThrowingStream<LLMStreamEvent, Error>
}

enum QueryScope {
    case global                     // Entire knowledge base
    case folder(RelativePath)       // Specific folder
    case document(DocumentID)       // Single document
    case selection                  // Only selected text + minimal context
    case web                        // Web search (Phase 2)
}

enum LLMStreamEvent {
    case token(String)
    case citation(DocumentID, excerpt: String)
    case done(LLMResponse)
    case error(Error)
}
```

### 7.4 `ContextBuilder`

Assembles the LLM's system context from KB documents.

```
Algorithm:
1. Run full-text search for terms in the user's prompt.
2. Add documents linked from the currently open note (graph neighbors).
3. Add documents recently viewed/modified (recency signal).
4. Score and rank by: FTS relevance + graph proximity + recency.
5. Greedily include top-scoring excerpts until token budget is ~70% full.
6. Reserve 30% for the response.
7. Prepend a system prompt describing the KB and the user's query task.
```

The system prompt template (configurable):

```
You are a personal research assistant for a knowledge base called "{vault_name}".
The user's notes are provided below as context. Your job is to:
- Answer questions by cross-referencing the provided notes.
- Cite specific notes when drawing on them (use the format [[Note Title]]).
- Point out contradictions or gaps in the user's notes when relevant.
- Be concise unless asked to elaborate.

Knowledge base context:
{document_excerpts}
```

### 7.5 Text Selection Actions

When a user selects text in the editor, a contextual popover appears with:

- **Ask AI** — opens the LLM chat panel with the selection pre-loaded as context.
- **Find related notes** — runs a search query derived from the selection, shows results in a panel.
- **Explain** — asks the LLM to explain the selected text in the context of the current note.
- **Find contradictions** — asks the LLM to find notes in the KB that contradict the selection.
- **Summarize** — summarizes a long selected passage.
- **Web search** *(Phase 2)* — searches the web for related articles.

### 7.6 LLM Chat Panel

A slide-in panel (right side of editor window):

- Persistent conversation history per document (stored in `.punkrecords/chats/<doc_id>.json`).
- Scope selector: KB-wide, current folder, current document, selection.
- Provider switcher (inline).
- Streamed token-by-token output with inline citations that are clickable wikilinks.
- "Copy to note" button on any AI response to insert it at cursor.

---

## 8. Search Architecture

### 8.1 Full-Text Search (Phase 1)

- **SQLite FTS5** with Porter stemming.
- Index rebuilt on first launch and incrementally updated on file changes.
- Search UI: `⌘F` for in-document, `⌘⇧F` for vault-wide.
- Results show: title, matching excerpt with highlights, tag matches, modification date.
- Supports: quoted phrases, `-exclusions`, `tag:swift` filters, `title:` prefix filters.

### 8.2 LLM-Assisted Search (Phase 1)

- Natural language query: "notes about attention mechanisms that mention transformers but not BERT".
- `LLMOrchestrator` receives the query with `scope: .global`.
- `ContextBuilder` does an FTS pre-pass to retrieve candidate documents.
- LLM re-ranks, filters, and explains which documents match and why.
- Results link directly to the matching documents.

### 8.3 Graph / Backlinks (Phase 1)

- Track `[[wikilinks]]` and markdown links between documents.
- Show backlinks panel: "Notes that link to this document."
- Graph view (visual node graph) is Phase 2.

### 8.4 Vector / Semantic Search (Phase 3)

- Generate embeddings for document chunks using an on-device embedding model (via MLX or FoundationModels).
- Store vectors in SQLite using `sqlite-vec` extension or a dedicated vector store.
- Enable "find semantically similar notes" regardless of keyword overlap.
- Hybrid search: combine FTS scores with vector similarity for ranking.

---

## 9. Testing Strategy

Tests live in a dedicated `PunkRecordsTests` package that has access to `PunkRecordsTestSupport` (mock implementations).

### 9.1 Unit Tests — `PunkRecordsCoreTests`

**Document Parsing**

- `MarkdownParserTests`
  - Parse H1/H2/.../H6 headers correctly
  - Parse all inline styles: bold, italic, bold-italic, strikethrough, inline code
  - Parse fenced code blocks with and without language identifiers
  - Parse ordered and unordered lists, nested lists, task lists
  - Parse tables (GFM)
  - Parse blockquotes (nested)
  - Parse wikilinks: `[[Target]]`, `[[Target|Alias]]`, unresolved wikilinks
  - Parse markdown links: `[text](url)`, `[text](relative/path.md)`, `[text](file.pdf)`
  - Parse YAML frontmatter: id, tags, dates; handle malformed frontmatter gracefully
  - Extract `linkedDocumentIDs` from both wikilinks and relative markdown links
  - Handle empty documents, documents with only frontmatter, documents with only content

- `DocumentTests`
  - Title derivation: from H1, then frontmatter `title:`, then filename
  - Tag normalization (lowercase, trim whitespace)
  - Document equality (by ID, not content)

**Search**

- `ContextBuilderTests`
  - Token budget is never exceeded
  - Documents ranked by relevance score (higher scores appear first)
  - Excerpts are trimmed at sentence boundaries, not mid-word
  - Empty KB produces empty context without errors
  - Single-document vault uses full document as context (within budget)

- `SearchQueryParserTests`
  - Parse quoted phrases: `"attention mechanism"` → exact match
  - Parse negation: `-BERT` → exclude term
  - Parse field filters: `tag:swift`, `title:notes`
  - Parse combined queries: `transformers -BERT tag:research`
  - Graceful handling of malformed queries

**LLM Layer**

- `LLMOrchestratorTests` (using `MockLLMProvider`)
  - Routes to default provider when none specified
  - Falls back to next available provider if primary `isAvailable()` returns false
  - Passes `selectedText` in request when provided
  - `scope: .document(id)` limits context to that document only
  - Streams events in correct order: `.token`, then `.done`

- `MockLLMProvider` (in `PunkRecordsTestSupport`)
  - Configurable responses and latency
  - Tracks all calls made for assertion

### 9.2 Unit Tests — `PunkRecordsInfraTests`

**Document Repository**

- `FileSystemDocumentRepositoryTests`
  - Reading a `.md` file produces a `Document` with correct content and metadata
  - Writing a `Document` produces a correctly formatted `.md` file with frontmatter
  - Files without frontmatter are assigned a stable ID on first read (ID written back)
  - Deleting a document removes the file
  - Moving a document updates the path without changing the ID
  - Listing documents in a folder returns all `.md` files recursively
  - Ignores paths matching `VaultSettings.ignoredPaths`

- `FSEventStreamWatcherTests`
  - File creation fires a `.added` change event
  - File modification fires a `.modified` change event
  - File deletion fires a `.deleted` change event
  - Rapid changes are debounced (only one event per file within 300ms window)
  - Events for ignored paths are filtered out

**Search Index**

- `SQLiteSearchIndexTests`
  - Index a document; search for a term from its body — document appears in results
  - Index a document; search for its title — document appears first
  - Re-index after content change — stale content no longer matches
  - Delete document from index — no longer appears in search results
  - FTS5 Porter stemmer: searching "running" matches "runs", "ran"
  - Quoted phrase search returns only exact matches
  - Tag filter: `tag:swift` returns only documents tagged `swift`
  - Empty query returns empty results (no crash)
  - Index survives app restart (SQLite persistence)
  - Concurrent reads do not deadlock
  - Index rebuild from scratch produces identical results to incremental updates

**LLM Providers**

- `AnthropicProviderTests` (using `URLProtocol` mock)
  - Correctly formats the Messages API request body
  - API key is read from Keychain, not passed as a parameter
  - Streaming response assembles tokens in order
  - HTTP 429 triggers retry with backoff
  - HTTP 401 throws `LLMError.unauthorized`
  - HTTP 500 throws `LLMError.providerError`
  - Network timeout throws `LLMError.timeout`

- `OpenAIProviderTests` (same approach)
  - Correctly formats Chat Completions request
  - Custom base URL is used when set (for Ollama compatibility)
  - Streaming SSE events parsed correctly
  - Error responses mapped to typed errors

- `FoundationModelsProviderTests`
  - `isAvailable()` returns false when Apple Intelligence not available (mocked)
  - Falls back without crashing on older OS
  - System prompt is correctly prepended to the request

### 9.3 Integration Tests — `PunkRecordsIntegrationTests`

These tests run against a real temporary directory on disk (no mocks for I/O).

**Document Lifecycle**

- Create a vault → write 5 documents → search for content → find all 5
- Save a document with wikilinks → backlinks are correctly indexed
- Modify a document → index is updated within 1 second
- Delete a document → no longer searchable; backlinks pointing to it are marked unresolved
- Rename a document → wikilinks that used the old name are updated (Phase 2; stub for now)

**iCloud Sync Simulation**

- Simulate an external file write (another device) by writing a file bypassing `NSFileCoordinator`
- Verify `FSEventStream` picks up the change and updates the index
- Simulate a conflicted copy appearing in the directory
- Verify conflict detection fires and the conflict is surfaced via the published stream

**LLM Context Assembly**

- Create a vault with 20 documents totaling ~50k tokens of content
- Issue a query with a 4k token context budget
- Verify that the assembled context never exceeds the budget
- Verify that the most relevant documents appear in context
- Issue the same query twice; verify deterministic context assembly

**End-to-End Search**

- Write documents with known content
- Full-text search returns correct results with highlights
- LLM-assisted search (with `MockLLMProvider`) correctly passes assembled context
- Search with no results returns empty array, not an error

### 9.4 UI Tests — `PunkRecordsUITests`

Using XCUITest.

- **Editor**
  - Open a document → content renders in preview mode
  - Toggle to raw mode → raw markdown is shown
  - Type in raw mode → autosave triggers → file on disk is updated
  - Select text → contextual popover appears with expected actions
  - Click a wikilink → navigates to target document
  - Click a `.pdf` link → PDF viewer opens

- **Search**
  - `⌘⇧F` opens vault search
  - Typing a query shows results
  - Clicking a result navigates to the document

- **LLM Panel**
  - Opening the panel when no provider configured → settings prompt shown
  - (With mock provider) submitting a query streams a response

### 9.5 Performance Tests

- Index build time for 1,000 documents < 5 seconds
- Search latency for full-text query < 100ms (P95)
- Editor renders a 10,000-word document without jank (frame drop test)
- App cold launch time < 2 seconds on M1 Mac

### 9.6 Test Infrastructure

- `PunkRecordsTestSupport` module: mock `LLMProvider`, mock `DocumentRepository`, in-memory SQLite index, temp-directory vault factory
- `MockURLProtocol` for intercepting network calls in `AnthropicProvider` and `OpenAIProvider` tests
- Snapshot tests (via `swift-snapshot-testing`) for rendered Markdown output to catch rendering regressions
- CI: run all unit + integration tests on every PR; UI tests on merge to `main`

---

## 10. Phase Breakdown

### Phase 1 — Foundation (Build First)

**Goal:** A working, usable Markdown KB with basic LLM assistance. No bells and whistles.

- [ ] `PunkRecordsCore` package: Document, Vault, MarkdownParser, DocumentRepository protocol, SearchService protocol, LLMProvider protocol, LLMOrchestrator (stub)
- [ ] `PunkRecordsInfra` package: FileSystemDocumentRepository, FSEventStream watcher, SQLite FTS5 index
- [ ] Basic SwiftUI app: sidebar (file tree), raw text editor, autosave
- [ ] iCloud Drive storage (basic: write files to container, no conflict UI yet)
- [ ] FoundationModels provider (on-device Apple Intelligence)
- [ ] LLM chat panel: KB-wide query, streamed response
- [ ] "Ask AI" on selected text
- [ ] Full-text search (`⌘⇧F`)
- [ ] Unit tests for all Core and Infra components
- [ ] Integration tests for document lifecycle and search

**Exit criteria:** Can create/edit/search notes and ask the on-device AI about KB content.

### Phase 2 — Rich Editing & Cloud Models

**Goal:** The full editor experience and all LLM providers.

- [ ] Preview mode editor (WYSIWYG-ish via `NSTextView`)
- [ ] GitHub-Flavored Markdown rendering (all GFM features)
- [ ] PDF embedding (view in-app via PDFKit)
- [ ] Wikilink navigation
- [ ] Backlinks panel
- [ ] Anthropic API provider
- [ ] OpenAI API provider (+ custom base URL for Ollama)
- [ ] API key management via Keychain
- [ ] Provider switcher in settings
- [ ] iCloud conflict resolution UI (side-by-side diff)
- [ ] Document rename with wikilink update
- [ ] Snapshot tests for markdown rendering

**Exit criteria:** Feature-complete editor. All four LLM providers working.

### Phase 3 — Intelligence & Power Features

**Goal:** Make the LLM integration genuinely powerful.

- [ ] MLX local model support (model download UI, model selection)
- [ ] Vector / semantic search (sqlite-vec + MLX embeddings)
- [ ] Hybrid search (FTS + vector)
- [ ] Graph view (visual note relationship map)
- [ ] Web search integration (Tavily or Brave Search API)
- [ ] "Find contradictions" LLM action
- [ ] Smart tagging suggestions
- [ ] Daily note / journal template
- [ ] Performance optimization pass

**Exit criteria:** Semantic search works. Local MLX models downloadable and usable.

### Phase 4 — Platform Expansion

- [ ] iOS app (iPad first)
- [ ] visionOS app
- [ ] Shared `PunkRecordsCore` across all platforms
- [ ] Platform-specific UI targets
- [ ] Sync conflict handling at scale

---

## 11. Open Questions & Decisions

### Must Decide Before Building Phase 1

1. **Minimum macOS version target.** FoundationModels requires macOS 26 (Tahoe). If we target macOS 26+, we get FoundationModels but limit the user base. If we target macOS 14/15, FoundationModels must be an optional enhancement. *Recommendation: target macOS 26 to make FoundationModels first-class, with graceful degradation.*

2. **Markdown AST library or roll our own?** Options: `swift-markdown` (Apple, CommonMark but not GFM), `cmark-gfm` (C library, GFM, needs bridging), custom parser. *Rolling a custom parser for Phase 1 raw mode is fine; GFM rendering for preview mode likely needs `cmark-gfm`.*

3. **SQLite library.** Options: `GRDB.swift` (well-maintained, expressive Swift API), raw `sqlite3` via `CSQLite`, or `SQLite.swift`. *Recommendation: GRDB.swift for its FTS5 support, migrations, and Swift concurrency support.*

4. **App Sandbox and iCloud Drive.** The app must be sandboxed for App Store distribution. iCloud Drive access requires the `com.apple.developer.ubiquity-container-identifiers` entitlement and correct iCloud capability setup. Decide on the iCloud container identifier now (usually `iCloud.com.yourname.PunkRecords`).

5. **Vault as iCloud container vs. user-chosen folder.** Two models: (a) always use the app's iCloud container (`FileManager.default.url(forUbiquityContainerIdentifier:)`), or (b) let the user pick any folder (including non-iCloud local folders). *Recommendation: support both — default to iCloud container, but allow "Open Local Vault" for users who want local-only or Dropbox/etc.*

### Decide Before Phase 2

6. **WYSIWYG editing approach.** Full WYSIWYG in `NSTextView` is complex. Alternatives: (a) side-by-side source/preview panes (simpler, Typora-like editing is Phase 2+), (b) `WKWebView` with CodeMirror or ProseMirror (JS dependency, not native), (c) custom `NSTextView` with attributed string rendering. *Recommendation: start with side-by-side in Phase 1, implement the custom `NSTextView` approach in Phase 2.*

7. **Syntax highlighting in raw mode.** `NSTextStorage` delegate with regex is simple but slow for large files. `tree-sitter` via `swift-tree-sitter` is accurate and fast but adds a dependency. *Recommendation: regex-based for Phase 1, evaluate tree-sitter for Phase 2.*

8. **Token counting.** Accurate token counting requires a tokenizer per provider (tiktoken for OpenAI, different for Anthropic). For context budget management, an approximation (1 token ≈ 4 chars) may be sufficient in Phase 1. Decide whether to ship with exact tokenizers or the approximation.

### Decide Before Phase 3

9. **Embedding model selection for semantic search.** Options: Apple's NLEmbedding (fast, on-device, English-only), a dedicated MLX embedding model (more capable, requires download), or a cloud embedding API. *Recommendation: NLEmbedding for Phase 3 initial cut, MLX embedding model as upgrade path.*

10. **Graph view library.** Options: a custom SwiftUI force-directed graph, an AppKit `CALayer`-based renderer, or an embedded WebView with D3.js. The graph could become complex. *Recommendation: WebView + D3.js for Phase 3 (graph is a nice-to-have, not a core feature; don't over-invest in native implementation early).*

---

*End of SPEC.md — v0.1*
