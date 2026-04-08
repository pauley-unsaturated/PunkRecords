# PunkRecords — Product & Technical Specification

> *Named after Dr. Vegapunk's Punk Records — the giant externalized brain on Egghead Island that stores all of Vegapunk's knowledge and lets his satellite bodies sync to it. PunkRecords does the same for your mind: your knowledge lives in the vault, LLMs process and enhance it, and you direct the whole thing.*

**Version:** 0.3
**Status:** Draft — Phase 1 decisions locked
**Platform:** macOS (primary), iOS / visionOS (future phases)
**Minimum macOS:** 15 (Sequoia). FoundationModels gated behind `@available(macOS 26, *)`.
**Distribution:** Direct (no App Store sandbox). App Store migration is a future option.

---

## Table of Contents

1. [Vision & Goals](#1-vision--goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Module Breakdown](#3-module-breakdown)
4. [Data Model](#4-data-model)
5. [Document Storage & Sync](#5-document-storage--sync)
6. [Markdown Editor Design](#6-markdown-editor-design)
7. [LLM Integration Layer](#7-llm-integration-layer)
8. [Search Architecture](#8-search-architecture)
9. [Testing Strategy](#9-testing-strategy)
10. [Phase Breakdown](#10-phase-breakdown)
11. [Open Questions & Decisions](#11-open-questions--decisions)

---

## 1. Vision & Goals

### What It Is

PunkRecords is a macOS-first personal knowledge base built on plain Markdown files, differentiated by deep, first-class LLM integration. It stores your notes, research, PDFs, and ideas in a folder of your choosing — fully portable, fully yours — while giving you an AI that doesn't just answer questions about your knowledge base, but actively builds and maintains it.

The key insight (inspired by [Karpathy's LLM Knowledge Bases workflow](https://x.com/karpathy/status/2039805659525644595)): **the LLM is not a sidebar chat — it's the primary author of the wiki.** You curate, direct, and query. The LLM writes, links, indexes, summarizes, and maintains. Raw sources go in, compiled knowledge comes out, and every interaction compounds the KB.

Think Obsidian meets Apple Intelligence, with escape hatches to Anthropic and OpenAI when you need more horsepower — and with the LLM as a first-class collaborator, not just an assistant.

### Core Principles

- **Your files, your format.** Notes are `.md` files on disk. No proprietary database. No lock-in.
- **Privacy first.** Default inference is on-device via Apple FoundationModels (macOS 26+). Cloud models are opt-in.
- **LLM as author, not just assistant.** The LLM writes wiki articles, compiles sources, maintains links, and keeps the KB healthy. You rarely edit the wiki manually — it's the domain of the LLM.
- **Every interaction compounds.** LLM outputs get filed back into the KB. Queries, summaries, and explorations always add up.
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
│  │  • Editor    │  │    Service     │  │  • LLMProviders     │ │
│  │  • Sidebar   │  │  • Search      │  │    (Foundation,     │ │
│  │  • LLM Chat  │  │    Service     │  │     Anthropic,      │ │
│  │  • Settings  │  │  • LLM         │  │     OpenAI)         │ │
│  │              │  │    Orchestrator│  │  • SQLiteIndex       │ │
│  └──────────────┘  └────────────────┘  └─────────────────────┘ │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   Persistence Layer                       │  │
│  │   User-chosen folder (.md files)  ·  SQLite (index only) │  │
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
| `NoteCompiler` | Orchestrates LLM-driven note creation: source compilation, save-as-note, KB enhancement |
| `MarkdownParser` | Wraps `cmark-gfm`; extracts links, tags, frontmatter |
| `SyntaxHighlighter` (protocol) | Abstraction for editor syntax highlighting |

### 3.2 `PunkRecordsInfra` (Swift Package)

Concrete implementations. Imports `cmark-gfm`, GRDB, network SDKs, FoundationModels (conditionally).

| Component | Responsibility |
|---|---|
| `FileSystemDocumentRepository` | Reads/writes `.md` files; watches via `FSEventStream` |
| `SQLiteSearchIndex` | Full-text search via FTS5; metadata and link graph indexing |
| `AnthropicProvider` | Anthropic Messages API client |
| `OpenAIProvider` | OpenAI Chat Completions API client (configurable base URL for Ollama/LM Studio) |
| `FoundationModelsProvider` | Apple on-device inference via FoundationModels framework (`@available(macOS 26, *)`) |
| `RegexSyntaxHighlighter` | Regex-based `NSTextStorage` highlighter (implements `SyntaxHighlighter` protocol) |
| `PDFRenderer` | Wraps PDFKit for in-app PDF viewing (Phase 2) |

### 3.3 `PunkRecordsUI` (App target)

SwiftUI views and AppKit integration.

| Component | Responsibility |
|---|---|
| `VaultBrowserView` | Sidebar: folder/file tree |
| `RawEditorView` | Syntax-highlighted raw text editor (Phase 1 only editor) |
| `LLMChatPanel` | Slide-in panel for KB-aware AI chat |
| `TextSelectionMenu` | Contextual menu on selected text: "Ask AI", "Find related" |
| `SearchView` | Full-text + LLM-assisted search UI |
| `SettingsView` | API keys, model selection, vault preferences |

Phase 2 additions:
| Component | Responsibility |
|---|---|
| `EditorView` | Split preview+raw or full-preview WYSIWYG |
| `MarkdownRenderer` | Live-rendered GFM view (read/preview mode) |
| `PDFViewerView` | Embedded PDF viewer (PDFKit) |

### 3.4 Supporting Packages

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
    var rootURL: URL            // User-chosen folder (local, iCloud, Dropbox, etc.)
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

Stored at `<vault_root>/.punkrecords/index.sqlite`. This is an **index only** — all source data lives in `.md` files on disk. The index is always rebuildable from scratch.

Three tables:

```sql
-- Full-text search via FTS5
CREATE VIRTUAL TABLE document_fts USING fts5(
    id UNINDEXED,
    title,
    body,
    tags,
    tokenize = 'porter ascii'
);

-- Document metadata cache (fast lookups without reading .md files)
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

## 5. Document Storage & Sync

### 5.1 Storage Layout

A vault is any user-chosen folder. PunkRecords creates a `.punkrecords/` subdirectory for its own data. The user is free to back the folder with iCloud Drive, git, Dropbox, or nothing at all.

```
<User-Chosen-Folder>/
├── .punkrecords/
│   ├── index.sqlite        ← Search index (rebuildable, not worth syncing)
│   └── vault.json          ← Vault settings
├── Notes/
│   ├── MyNote.md
│   └── Subfolder/
│       └── AnotherNote.md
└── Attachments/
    └── paper.pdf
```

### 5.2 File Watching

- Use `FSEventStream` (via `FileSystemDocumentRepository`) to watch the vault root directory tree.
- On file events: debounce 300ms, re-read changed files, update SQLite index, publish changes to UI via `AsyncStream<VaultChange>`.
- Standard file I/O — no `NSFileCoordinator` in Phase 1. The vault is treated as a local folder.

### 5.3 Sync & Conflicts

PunkRecords is **sync-agnostic**. The vault is a folder; the user decides how to sync it.

**Phase 1:** No conflict detection or resolution. If the user syncs via iCloud Drive and a conflict occurs, iCloud creates a `filename (conflicted copy ...).md` file which simply appears as a new document in the sidebar. This is acceptable — the user can manually compare and delete.

**Phase 2+:** Detect iCloud-style conflicted copy filenames in the `FSEventStream` handler, surface a conflict banner, and offer side-by-side diff resolution. This change is isolated to the file-watching layer — no architectural rework needed.

### 5.4 New Vault Creation

1. User picks a folder (or creates a new one via the file picker).
2. App creates `.punkrecords/` subdirectory.
3. Writes `vault.json` with default settings.
4. Performs initial full index build.
5. Adds vault to app's `VaultRegistry` (stored in UserDefaults).

---

## 6. Markdown Editor Design

### 6.1 Phase 1: Raw Editor

A single-pane raw Markdown editor with syntax highlighting.

- Plain text editor showing the raw `.md` source.
- Syntax highlighting via `RegexSyntaxHighlighter` (implements the `SyntaxHighlighter` protocol), applied through an `NSTextStorage` delegate.
- The `SyntaxHighlighter` protocol is the abstraction boundary — in Phase 2+ we can swap in a `TreeSitterSyntaxHighlighter` without changing the editor.
- Supports GFM syntax highlighting: headers, bold, italic, strikethrough, inline code, fenced code blocks, blockquotes, lists, task lists, links, wikilinks.

```swift
protocol SyntaxHighlighter: Sendable {
    func highlight(_ text: String) -> NSAttributedString
    func incrementalHighlight(_ text: String, editedRange: NSRange) -> [SyntaxHighlight]
}

struct SyntaxHighlight {
    let range: NSRange
    let style: HighlightStyle
}
```

### 6.2 Wikilinks

`[[Note Title]]` or `[[Note Title|Display Text]]`

- Rendered as tappable links in the editor. Clicking navigates to the target note.
- Unresolved wikilinks shown in a distinct style (e.g., dashed underline, different color).
- On save, `linkedDocumentIDs` in the document model is updated for backlink tracking.

### 6.3 Editor State

```swift
@Observable
final class DocumentEditorViewModel {
    var document: Document
    var isDirty: Bool
    var selectionRange: NSRange?
    var isSaving: Bool

    func save() async throws
    func applyLLMSuggestion(_ text: String, at range: NSRange) async
}
```

### 6.4 Autosave

- Debounced autosave: 2 seconds after last keystroke.
- Manual save: `⌘S` (immediate).
- Dirty indicator in window title (`•` prefix, standard macOS convention).
- Autosave writes through `DocumentRepository`.

### 6.5 Phase 2: Preview Mode

Deferred to Phase 2. Will add:

- A WYSIWYG-ish preview mode via custom `NSTextView` subclass.
- Toggle between raw and preview: `⌘⇧P`.
- Both modes share the same `DocumentEditorViewModel`.
- PDF embedding (inline PDF card, click to open `PDFView`).

---

## 7. LLM Integration Layer

### 7.1 Provider Abstraction

All inference goes through a single protocol:

```swift
protocol LLMProvider: Actor {
    var id: LLMProviderID { get }
    var displayName: String { get }
    var capabilities: LLMCapabilities { get }
    var maxContextTokens: Int { get }

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
    case anthropic        = "anthropic"
    case openAI           = "openai"
}
```

### 7.2 Provider Implementations (Phase 1)

**`AnthropicProvider`**

- Calls the Anthropic Messages API (`/v1/messages`).
- API key stored in macOS Keychain (never in UserDefaults or files).
- Supports streaming via SSE.
- Default model: `claude-sonnet-4-6` (configurable).
- Handles rate limits with exponential backoff.

**`OpenAIProvider`**

- Calls OpenAI Chat Completions API (`/v1/chat/completions`).
- API key stored in Keychain.
- Supports streaming.
- Default model: `gpt-4o` (configurable).
- **Configurable base URL** — supports OpenAI-compatible endpoints out of the box:
  - Ollama: `http://localhost:11434/v1`
  - LM Studio: `http://localhost:1234/v1`
  - Any other OpenAI-compatible API
- When using a local endpoint, API key can be left empty or set to a dummy value.

**`FoundationModelsProvider`** (Phase 1, gated)

- Uses Apple's `FoundationModels` framework.
- Gated behind `@available(macOS 26, *)`. Not available on macOS 15.
- `isAvailable()` returns false on older OS or unsupported hardware.
- Falls back gracefully — never crashes, just reports unavailability.
- Privacy: no data leaves the device.

### 7.3 `LLMOrchestrator`

The orchestrator sits above the providers and manages:

1. **Provider selection** — default provider from settings; user can switch per-request.
2. **Context assembly** — calls `ContextBuilder` to find and rank relevant KB documents.
3. **Token budget management** — queries the provider's `maxContextTokens` and scales context accordingly.
4. **Request routing** — if selected provider unavailable, falls back to next enabled provider (opt-in setting).
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
}

enum LLMStreamEvent {
    case token(String)
    case citation(DocumentID, excerpt: String)
    case done(LLMResponse)
    case error(Error)
}
```

### 7.4 `ContextBuilder`

Assembles the LLM's system context from KB documents. **Scales automatically based on provider context size.**

```
Context tiers (based on provider maxContextTokens):

Small (< 4k tokens) — e.g., small on-device models:
  - Current document only, truncated to fit.
  - No KB-wide search. Operates as "chat about this note."

Medium (4k–32k tokens) — e.g., smaller cloud models, local Ollama models:
  - Current document + top FTS hits for query terms.
  - Simple relevance ranking.
  - Reserve 30% of budget for response.

Large (32k+ tokens) — e.g., Claude, GPT-4o:
  1. Run full-text search for terms in the user's prompt.
  2. Add documents linked from the currently open note (graph neighbors).
  3. Add documents recently viewed/modified (recency signal).
  4. Score and rank by: FTS relevance + graph proximity + recency.
  5. Greedily include top-scoring excerpts until token budget is ~70% full.
  6. Reserve 30% for the response.
  7. Prepend system prompt describing the KB and the user's query task.
```

Token estimation in Phase 1 uses the approximation **1 token ~ 4 characters**. Exact tokenizers per provider are a Phase 3 optimization.

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
- **Summarize** — summarizes a long selected passage.

Phase 2 additions:
- **Find contradictions** — asks the LLM to find notes in the KB that contradict the selection.
- **Web search** — searches the web for related articles.

### 7.6 LLM Chat Panel

A slide-in panel (right side of editor window):

- **Ephemeral conversation** — chat history clears when the panel is closed. Persistent history is Phase 2.
- Scope selector: KB-wide, current folder, current document, selection.
- Provider switcher (inline).
- Streamed token-by-token output with inline citations that are clickable wikilinks.
- **"Save as note"** button on any AI response — creates a new `.md` file from the response. The LLM generates a title, frontmatter tags, and wikilinks to related notes. The new note is filed into the vault and indexed immediately. This is the minimum viable "LLM writes the wiki" feature.
- "Insert at cursor" button to paste a response into the current document.

### 7.7 LLM as Wiki Author

The core differentiator. The LLM doesn't just answer questions — it produces and maintains wiki content.

**Phase 1: Save as Note + Compile from Source**

- **Save as note** (from chat panel): Any substantive LLM response can be saved as a new wiki article with one click. The LLM generates title, tags, and wikilinks. The user confirms the destination folder and can edit before saving.

- **Compile note from source**: Select a document (PDF, long raw text, pasted article) and ask the LLM to produce a summarized, structured wiki article from it. The LLM:
  1. Reads the source material.
  2. Generates a structured `.md` article with title, sections, tags, and wikilinks to existing KB notes.
  3. Presents a preview. User confirms or edits before saving.
  4. Files the new note into the vault.

  This is accessible via:
  - Right-click a file in the sidebar → "Compile to wiki article"
  - Select text → "Compile selection to note"
  - Chat panel → "Compile this to a note" (when discussing raw material)

**Phase 2: Raw Sources Convention + LLM Linting**

- **Raw sources directory**: Support a `Sources/` (or user-configured) directory convention for unprocessed material — articles, papers, PDFs, clippings. The LLM can be pointed at sources to compile into wiki notes. Not a hard boundary, just a UX convention and a scope option (`scope: .folder("Sources/")`). The sidebar visually distinguishes source material from compiled wiki notes.

- **LLM linting / health checks**: A "Review vault" command that runs the LLM across the KB looking for:
  - Inconsistent or contradictory information across notes
  - Missing data that could be filled in (with web search in Phase 3)
  - Opportunities for new connections and cross-links
  - Stale or outdated information
  - Orphaned notes with no incoming or outgoing links
  
  Results are presented as actionable suggestions — each one can be applied (creating/editing a note) or dismissed. This runs on-demand, not automatically.

---

## 8. Search Architecture

### 8.1 Full-Text Search (Phase 1)

- **SQLite FTS5** with Porter stemming, via **GRDB.swift**.
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
- Graph view (visual node graph) is Phase 2+.

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
  - Context tier selection matches provider's `maxContextTokens`
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

- `NoteCompilerTests` (using `MockLLMProvider` and `MockDocumentRepository`)
  - "Save as note" generates valid frontmatter (id, tags, created date)
  - "Save as note" generates wikilinks to existing KB documents when relevant
  - "Compile from source" produces a structured article with title, sections, and tags
  - "Compile from source" links to existing KB notes found via search
  - Generated note is written through `DocumentRepository`
  - User can edit the generated note before saving (preview step)

- `MockLLMProvider` (in `PunkRecordsTestSupport`)
  - Configurable responses and latency
  - Configurable `maxContextTokens` for testing context tier logic
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
  - Custom base URL is used when set (for Ollama/LM Studio compatibility)
  - Streaming SSE events parsed correctly
  - Error responses mapped to typed errors

- `FoundationModelsProviderTests`
  - `isAvailable()` returns false on macOS < 26 or unsupported hardware
  - Falls back without crashing on older OS
  - System prompt is correctly prepended to the request

**Syntax Highlighter**

- `RegexSyntaxHighlighterTests`
  - Headers highlighted correctly (H1–H6)
  - Bold, italic, strikethrough, inline code highlighted
  - Fenced code blocks highlighted (including language identifier)
  - Wikilinks and markdown links highlighted
  - Incremental highlighting updates only edited ranges

### 9.3 Integration Tests — `PunkRecordsIntegrationTests`

These tests run against a real temporary directory on disk (no mocks for I/O).

**Document Lifecycle**

- Create a vault → write 5 documents → search for content → find all 5
- Save a document with wikilinks → backlinks are correctly indexed
- Modify a document → index is updated within 1 second
- Delete a document → no longer searchable; backlinks pointing to it are marked unresolved

**LLM Context Assembly**

- Create a vault with 20 documents totaling ~50k tokens of content
- Issue a query with a 4k token context budget
- Verify that the assembled context never exceeds the budget
- Verify that the most relevant documents appear in context
- Issue the same query twice; verify deterministic context assembly
- Test all three context tiers (small/medium/large) with mock providers reporting different `maxContextTokens`

**Note Compilation**

- "Save as note" from a mock LLM response → new `.md` file appears on disk with valid frontmatter
- "Compile from source" with a long text document → produces a structured wiki article that links to existing notes
- Compiled note appears in search index immediately after save
- Compiled note's wikilinks are tracked in the link graph

**End-to-End Search**

- Write documents with known content
- Full-text search returns correct results with highlights
- LLM-assisted search (with `MockLLMProvider`) correctly passes assembled context
- Search with no results returns empty array, not an error

### 9.4 UI Tests — `PunkRecordsUITests`

Using XCUITest.

- **Editor**
  - Open a document → raw markdown is shown with syntax highlighting
  - Type in editor → autosave triggers → file on disk is updated
  - Select text → contextual popover appears with expected actions
  - Click a wikilink → navigates to target document

- **Search**
  - `⌘⇧F` opens vault search
  - Typing a query shows results
  - Clicking a result navigates to the document

- **LLM Panel**
  - Opening the panel when no provider configured → settings prompt shown
  - (With mock provider) submitting a query streams a response
  - "Save as note" on a response → new note created, appears in sidebar
  - "Compile to wiki article" on a source file → preview shown, confirm creates note

### 9.5 Performance Tests

- Index build time for 1,000 documents < 5 seconds
- Search latency for full-text query < 100ms (P95)
- Editor renders a 10,000-word document without jank (frame drop test)
- App cold launch time < 2 seconds on M1 Mac

### 9.6 Test Infrastructure

- `PunkRecordsTestSupport` module: mock `LLMProvider`, mock `DocumentRepository`, in-memory SQLite index, temp-directory vault factory
- `MockURLProtocol` for intercepting network calls in `AnthropicProvider` and `OpenAIProvider` tests
- Snapshot tests (via `swift-snapshot-testing`) for rendered Markdown output to catch rendering regressions (Phase 2)
- CI: run all unit + integration tests on every PR; UI tests on merge to `main`

---

## 10. Phase Breakdown

### Phase 1 — Foundation (Build First)

**Goal:** A working, usable Markdown KB with LLM assistance via Anthropic/OpenAI. No bells and whistles.

- [ ] `PunkRecordsCore` package: Document, Vault, MarkdownParser (cmark-gfm), DocumentRepository protocol, SearchService protocol, LLMProvider protocol, LLMOrchestrator, ContextBuilder with tiered context scaling, SyntaxHighlighter protocol
- [ ] `PunkRecordsInfra` package: FileSystemDocumentRepository, FSEventStream watcher, SQLite FTS5 index (GRDB), RegexSyntaxHighlighter
- [ ] Anthropic API provider (Messages API, streaming, Keychain storage)
- [ ] OpenAI-compatible API provider (configurable base URL for Ollama/LM Studio)
- [ ] FoundationModels provider (gated behind `@available(macOS 26, *)`)
- [ ] Basic SwiftUI app: sidebar (file tree), raw text editor with syntax highlighting, autosave
- [ ] User-chosen vault folder (no iCloud assumptions)
- [ ] LLM chat panel: KB-aware query with ephemeral history, streamed response, scope selector
- [ ] "Save as note" from LLM responses (LLM generates title, tags, wikilinks)
- [ ] "Compile note from source" — LLM summarizes a document/selection into a structured wiki article
- [ ] "Ask AI" on selected text
- [ ] Full-text search (`⌘⇧F`)
- [ ] Backlinks panel
- [ ] Unit tests for all Core and Infra components
- [ ] Integration tests for document lifecycle, search, and context assembly

**Exit criteria:** Can create/edit/search notes and ask Claude or a local model about KB content. LLM can author new wiki notes from sources and chat responses. Context scales automatically to provider capabilities.

### Phase 2 — Rich Editing & Polish

**Goal:** The full editor experience and production polish.

- [ ] Preview mode editor (WYSIWYG-ish via `NSTextView`)
- [ ] GitHub-Flavored Markdown rendering (all GFM features)
- [ ] PDF embedding (view in-app via PDFKit)
- [ ] Wikilink navigation (click to open target)
- [ ] iCloud conflict detection and resolution UI (side-by-side diff)
- [ ] Document rename with wikilink update
- [ ] Persistent chat history per document
- [ ] Raw sources directory convention (`Sources/`) with visual distinction in sidebar
- [ ] LLM vault linting / health checks ("Review vault" command with actionable suggestions)
- [ ] Snapshot tests for markdown rendering
- [ ] Tree-sitter syntax highlighting (evaluate and swap in if worthwhile)

**Exit criteria:** Feature-complete editor. LLM can maintain the wiki (lint, suggest connections, compile sources). Conflict resolution works. Ready for daily use by a small group.

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
- [ ] Exact tokenizers per provider (replace 4-char approximation)
- [ ] Performance optimization pass

**Exit criteria:** Semantic search works. Local MLX models downloadable and usable.

### Phase 4 — Platform Expansion

- [ ] iOS app (iPad first)
- [ ] visionOS app
- [ ] Shared `PunkRecordsCore` across all platforms
- [ ] Platform-specific UI targets
- [ ] App Store distribution (sandbox migration)
- [ ] Sync conflict handling at scale

---

## 11. Open Questions & Decisions

### Resolved

| # | Question | Decision |
|---|----------|----------|
| 1 | Minimum macOS version | macOS 15 (Sequoia). FoundationModels gated behind `@available(macOS 26, *)`. |
| 2 | Markdown parser | `cmark-gfm` from day one. Full GFM support, no rewrites between phases. |
| 3 | SQLite library | GRDB.swift. Index only — no markdown content stored in SQL beyond FTS5 needs. |
| 4 | Vault model | User-chosen folder. No iCloud assumptions. User decides their own backup/sync. |
| 5 | App Sandbox | Not sandboxed (direct distribution). App Store sandbox migration is Phase 4. |
| 6 | Phase 1 editor | Single-pane raw editor with regex syntax highlighting. Preview mode is Phase 2. |
| 7 | Phase 1 LLM providers | Anthropic + OpenAI-compatible (with configurable base URL for Ollama/LM Studio). FoundationModels gated but included. |
| 8 | Context scaling | Automatic tier selection (small/medium/large) based on provider's `maxContextTokens`. |
| 9 | Chat persistence | Ephemeral in Phase 1. Persistent per-document history in Phase 2. |
| 10 | Conflict resolution | Ignored in Phase 1 (conflicts appear as separate files). Detection + resolution UI in Phase 2. |
| 11 | Syntax highlighting | Regex-based in Phase 1, behind a `SyntaxHighlighter` protocol so tree-sitter can be swapped in later. |
| 12 | Distribution | Direct distribution. No App Store for now. |
| 13 | Target audience | Personal use first (developer + close circle), then expand. |
| 14 | LLM role | LLM is the primary wiki author, not just a chat assistant. Save-as-note and compile-from-source in Phase 1. Vault linting and raw sources convention in Phase 2. Inspired by [Karpathy's LLM KB workflow](https://x.com/karpathy/status/2039805659525644595). |

### Decide Before Phase 2

1. **WYSIWYG editing approach.** Custom `NSTextView` with attributed string rendering vs. side-by-side source/preview panes vs. `WKWebView` with ProseMirror/CodeMirror. Need to evaluate complexity vs. user experience.

2. **Token counting.** Phase 1 uses 1 token ~ 4 chars approximation. Evaluate whether exact tokenizers (tiktoken for OpenAI, Anthropic's tokenizer) are needed for Phase 2 or can wait for Phase 3.

### Decide Before Phase 3

3. **Embedding model selection for semantic search.** Options: Apple's NLEmbedding (fast, on-device, English-only), a dedicated MLX embedding model (more capable, requires download), or a cloud embedding API.

4. **Graph view implementation.** Custom SwiftUI force-directed graph vs. AppKit `CALayer` renderer vs. embedded WebView with D3.js.

---

*End of SPEC.md — v0.2*
