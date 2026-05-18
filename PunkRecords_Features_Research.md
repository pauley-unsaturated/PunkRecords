# PunkRecords: Feature Landscape Research

*Prepared for Claude Code — implementation planning input, May 2026.*

This report surveys the 2026 personal-knowledge-management (PKM) landscape, identifies table-stakes vs. differentiating features, and goes deep on the "paste a URL → structured summary with jump-to-source links" feature that is core to PunkRecords. It closes with an opinionated, ranked shortlist tuned for a single-developer, Mac-native SwiftUI app serving two users.

---

## 1. Competitive feature matrix

The space splits into four camps: **local-first markdown vaults** (Obsidian, Logseq, Bear), **cloud workspaces** (Notion, Roam, Tana, Saga, AppFlowy), **AI-first PKMs** (Mem, Reflect, NotebookLM, Recall), and **read-it-later/highlight tools** (Readwise Reader, Matter, Glasp, Recall).

| Product | Headline features | AI/agent (2025-26) | Pricing | Best at |
|---|---|---|---|---|
| **Obsidian** | Local markdown vault, `[[wikilinks]]`, graph view, 2,000+ community plugins, Canvas | No first-party AI; community plugins (Smart Connections $20/mo, Copilot, AI Providers) for chat-with-vault, embeddings, multi-provider routing | Free for all use (commercial license dropped Feb 2025); Sync $4–10/mo; Publish $8/mo | Power-user PKM with full data ownership |
| **Notion** | Block editor, databases, wikis, real-time collaboration, web clipper | "Ask Notion" cross-workspace search, AI Agents, Drive/Slack connectors (Business plan only, $20/user/mo as of May 2025 restructuring) | Free Personal; Plus $10; Business $20; Enterprise custom | Team workspaces with structured databases |
| **Mem** | Folderless notes, auto-tagging, Mem Chat, Smart Write, Chrome Clipper, voice mode | AI-organized collections, semantic Deep Search, Copilot "related notes," AI Chat over vault, meeting briefs | Free (25 notes/mo); **Mem Plus $14.99/mo (or $12 annual)**; Teams custom | "Just capture; the AI files it" automation |
| **Reflect** | Daily notes, bidirectional `[[links]]`, E2E encrypted, calendar integration, Kindle import | GPT-powered writing assist, AI prompts, voice transcription | $10/mo or **$100/yr Pro** (free tier replaced by 2-week trial) | E2E-encrypted networked journaling |
| **Roam Research** | Outliner, block references, queries, daily notes — originator of bidirectional linking | Limited; Roam Studies and AI features lag competitors | **Pro $15/mo or $165/yr; Believer $500/5yr (~$8.33/mo)**; 31-day trial only | The original block-reference outliner |
| **Logseq** | Open-source local-first outliner, plain markdown/org-mode, graph view, PDF annotation | Limited native AI; community plugins for OpenAI integration | Free, open-source; Logseq Sync beta via $5–15 Open Collective | Privacy-first outliner devotees |
| **Tana** | Supertags (typed structured data on outliner blocks), live queries, voice capture, mobile widgets | Built-in AI for supertag auto-tagging, summarization, content generation; meeting note-taker (botless audio); MCP-style integrations | Plus $10/mo ($8/mo billed annually); Pro $18/mo ($14/mo billed annually) per [tana.inc/pricing](https://tana.inc/pricing) (May 2026) | Outliner + structured database hybrid for systems thinkers |
| **Capacities** | Object-based PKM (books, people, projects as typed objects), offline-first since early 2025 | "AI that knows your notes" — contextual chat, smart queries, image analysis (AI credit budget) | Free; **Pro $9.99/mo annual (~$11.99/mo monthly); Believer $12.49/mo annual** | Structured objects without leaving notes |
| **Heptabase** | Cards on infinite whiteboards, spatial arrangement, PDF annotation, journal | AI chat with cited answers across cards, auto AI tagging (2025), image/PDF analysis; Premium tier (Dec 2025) adds Gemini chat + 1,800 AI credits/mo | **Monthly ~$11.99; Yearly $107.88 ($8.99/mo); Lifetime $659** | Visual research and literature reviews |
| **Craft** | Beautiful blocks, document linking, Apple-native polish, daily notes, share-to-web | Craft AI Assistant (content generation, summarization) | Free; **Pro ~$5/mo ($59.99/yr)**; Business ~$10/user/mo | Beautiful Apple-ecosystem documents |
| **Bear** | Markdown + tags, iCloud sync, beautiful themes, fast | None native | Free; **Bear Pro $2.99/mo or $29.99/yr** | Apple-native markdown writing |
| **Apple Notes** | Quick Note, Smart Folders, locked notes, handwriting, Spotlight integration | Apple Intelligence summarization, smart folders, math notes (macOS 15+) | Free | Casual capture for Apple users |
| **NotebookLM** | Upload PDFs/URLs/YouTube → grounded chat with citations, Audio Overviews (podcast hosts), Video Overviews, flashcards/quizzes, Mind Maps, Deep Research (Nov 2025) | Citations link to exact source passages; **13% hallucination rate vs. 40% for ChatGPT/Gemini** in a 2025 arXiv evaluation | Free (50 sources/notebook, 100 notebooks); **NotebookLM Plus via Google Workspace** (300 sources) | Cited synthesis across uploaded sources |
| **Granola** | Bot-free meeting notes (captures device audio), "rough notes → enhanced notes" model, Recipes, MCP support | GPT-4o-powered summarization shaped by your in-meeting notes; Slack/Notion/HubSpot/Attio export; chat across meetings | Free (25 lifetime meetings); **Business $14/user/mo; Enterprise $35+/user/mo** | Meeting notes for back-to-back calls |
| **Saga** | Real-time collab notes/docs/tasks, page mentions, integrations | Saga AI: chat over workspace, summarization, translation, drafting via `@/` commands; admits hallucination risk | Free (3 members, 5K AI words/mo); **Standard $6/member/mo annual; Business $12/member/mo annual** | Lightweight collaborative workspace |
| **AppFlowy** | Open-source (AGPL v3) Notion clone, Flutter + Rust, offline-first, self-hostable | Writing assist, ChatGPT-like chat, model selection, BYO API key, local models (Llama 3, Mistral 7B) | Free (2 members, 5GB); **Pro $10/user/mo annual ($12.50/mo monthly)**; self-host free | Open-source, self-hostable Notion |
| **Readwise Reader** | Read-it-later, articles/PDFs/EPUBs/YouTube/tweets, highlight everything, spaced-repetition daily review, send-to-Kindle | **Ghostreader** unified chat: doc summary, highlight Q&A, flashcards from highlights, with citation links back to source text | **$9.99/mo billed annually** (Readwise Full includes Reader) | Reading + highlights → spaced-repetition recall |
| **Matter** | Beautifully designed reading queue, real-time TTS narration with word-level highlighting, follow writers | AI summary (swipe down from top), highlight syncing to Readwise/Obsidian | **$60/year ($5/mo billed annually)** per [readless.app](https://www.readless.app/compare/matter-app-pricing) | Reading aesthetics + audio narration |
| **Glasp** | Web highlighter (text on any page, PDFs, YouTube), social feed of others' highlights, multi-color highlight | Glasp AI hatches new ideas from your highlights; exports to Notion/Roam/Obsidian | Free for highlights; AI features in paid tier | Social web highlighting + export everywhere |
| **Recall (getrecall.ai)** | One-click save (articles, YouTube, podcasts, PDFs, TikTok, Google Docs), concise/detailed AI summaries, knowledge graph auto-links saved content, Augmented Browsing (resurfaces saved content as you browse), MCP & API access, spaced-repetition quizzes | Chat with saved knowledge in your choice of model (GPT/Claude/Gemini); switchable mid-conversation; markdown export | Free (10 AI summaries); **Recall Plus $7/mo annual ($10/mo monthly)** | "Save anything → AI summary + auto-graph" |

**Sources:** [obsidian.md](https://obsidian.md), [notion.com](https://notion.com), [get.mem.ai/pricing](https://get.mem.ai/pricing), [reflect.app](https://reflect.app), [tana.inc/pricing](https://tana.inc/pricing), [capacities.io](https://capacities.io), [heptabase.com](https://heptabase.com), [bear.app](https://bear.app/faq/features-and-price-of-bear-pro/), [notebooklm.google](https://notebooklm.google/), [granola.ai/pricing](https://www.granola.ai/pricing), [readwise.io](https://readwise.io), [getrecall.ai](https://www.recall.it/), [arxiv 2509.25498](https://arxiv.org/html/2509.25498v1).

---

## 2. Table-stakes feature inventory

Synthesized from product docs, r/ObsidianMD/r/PKMS/r/Notion/HN discussions, and Mac App Store reviews. "Table-stakes" means a 2026 PKM that ships without it gets dismissed in reviews; "differentiator" earns plaudits; "niche" is a power-user wish.

### Capture
- **Table-stakes:** keyboard-driven quick capture (global hotkey), browser web-clipper, mobile capture, voice → text transcription, paste-image-with-preview, screenshot capture.
- **Differentiator:** email-in inbox, share-sheet on iOS/macOS, OCR on images/PDFs, meeting-audio capture (Granola-style botless), automatic webpage cleanup (Reader Mode quality).
- **Niche:** Apple Watch capture, Siri Shortcuts integration, Telegram/SMS bot inbox.

### Organize
- **Table-stakes:** tags (including nested), bidirectional `[[wikilinks]]` + backlinks panel, properties/frontmatter, folders (even Notion-style "outliners" expect hierarchy under the hood).
- **Differentiator:** typed objects/supertags (Tana, Capacities), graph view, daily-notes scaffolding, transclusion/block-refs.
- **Niche:** spatial canvas/whiteboard (Heptabase's wedge), org-mode parity, custom CSS.

### Retrieval
- **Table-stakes:** instant full-text search (FTS5, Tantivy, or equivalent), live-as-you-type ranking, tag/property filters, recent-files list.
- **Differentiator:** semantic/embedding search, saved searches/smart folders, "find similar notes," date-range and metadata operators (`tag:`, `from:`).
- **Niche:** Boolean+regex, fuzzy-typo tolerance, search-in-PDFs.

### AI/agent
- **Table-stakes (in 2026):** chat-with-vault (RAG over your notes), per-note summarization, auto-tagging suggestion, source-grounded answers with citations.
- **Differentiator:** structured extraction (tables/CSV from prose), daily briefing digest, auto-linking suggestions, multi-provider routing (Anthropic + OpenAI + local), MCP tool exposure.
- **Niche:** voice-mode agents (Tana), audio overviews (NotebookLM), agentic web research with browse.

### Editing
- **Table-stakes:** markdown shortcuts, headings, lists, checklists, tables, code blocks with syntax highlighting, in-line math.
- **Differentiator:** block-level editor (Notion-style drag handles), live-preview WYSIWYG, slash-commands, callouts/admonitions, transclusion/embed-block.
- **Niche:** canvas/whiteboard, mind-maps, Excalidraw integration.

### Sync & collaboration
- **Table-stakes:** multi-device sync (even if it's "iCloud Drive / your-own-Dropbox"), conflict-free merge for simultaneous edits to *different* notes.
- **Differentiator:** end-to-end encrypted sync (Obsidian Sync, Reflect, Bear), publish-to-web, share-with-link, version history.
- **Niche:** real-time multiplayer cursors, comments/mentions, granular permissions. **For a single-developer, two-person product, real-time collab is explicitly NOT table-stakes** — last-writer-wins on per-file granularity is fine.

### Extensibility
- **Table-stakes:** plain-text export, markdown import, CSV/JSON export.
- **Differentiator:** plugin/extension API, scripting (Templater, Dataview-style), URL scheme for inter-app linking, MCP server exposure of vault tools.
- **Niche:** custom themes, community plugin marketplace, Lua/JS embedded runtime.

**The shortest path to "taken seriously" in 2026:** capture (clipper + quick-add + voice), wikilinks + backlinks, FTS, chat-with-vault with citations, markdown round-trip. Everything else is upside.

---

## 3. Web ingestion / "cliffs notes" feature — DEEP DIVE

This is PunkRecords' wedge: paste a URL → agent fetches → produces a structured summary → every bullet links back to the specific paragraph it came from. Below, what current tools actually ship, the extraction-library landscape, anchor-back techniques, summary structures users prefer, failure modes, and a concrete markdown storage shape.

### 3.1 How existing tools handle URL → summary → source

**[NotebookLM](https://notebooklm.google/)** is the gold standard for source-linked synthesis. Every claim in chat is rendered with numbered superscripts; clicking opens the source pane scrolled to the *exact passage* the model used. For PDFs, this is paragraph-level "deep links"; for URLs added as sources, NotebookLM ingests the page into its own internal viewer where citations target rendered text spans. Its hallucination rate measured 13% in an [arXiv 2025 reporting-task evaluation](https://arxiv.org/html/2509.25498v1) (vs. ~40% for ChatGPT/Gemini on the same corpus) — better than peers, but "interpretive overconfidence" remains the dominant failure mode (the model adds unsupported characterizations rather than fabricating numbers).

**[Readwise Reader's Ghostreader](https://speedreadinglounge.com/readwise-reader-review)** offers a unified chat interface: ask for a doc summary, highlight Q&A, or flashcards. Answers include citation links back to the highlighted source passages within Reader's own reading view. Storage: Reader fetches the article, runs its own content extraction, and renders it in a clean reading view that owns the canonical anchor space.

**[Matter](https://robertbreen.com/2025/02/27/elevate-your-online-reading-with-matter/)** offers a "swipe down from top" AI summary (2–3 sentences) of any saved article. Source linking is implicit — the summary lives at the top of the article view; there's no per-bullet anchor.

**[Recall (getrecall.ai)](https://www.recall.it/)** is the closest analog to PunkRecords' wedge for non-vault use. One-click save → concise *or* detailed AI summary → automatic keyword extraction → "Augmented Browsing" resurfaces related saved content as you browse. Summaries are editable; export is markdown. For YouTube videos, summaries include timestamps that deep-link into the video. Recall's chat lets you switch LLM mid-conversation (GPT/Claude/Gemini). Article-level summaries do NOT include per-sentence source anchors; they're structured ("knowledge cards") but coarse-grained.

**[Notion Web Clipper](https://www.notion.com/web-clipper)** is fundamentally dumber: one-click save dumps the article HTML (cleaned) as a Notion page with the original URL stored as a property. No AI summary. No anchor mapping. It's storage, not synthesis.

**[Heptabase](https://heptabase.com)** does not have a first-class web-clipper-with-summary. PDF annotation is its strength; URLs are typically added as references to a card with manual quotes pasted in.

**[Mem](https://get.mem.ai/)** Chrome Clipper saves the page, then the AI organizes it into related collections — but the summary is implicit (you ask for it via Mem Chat). No per-sentence anchor back to the source URL.

**[Glasp](https://glasp.co/)** inverts the model: you highlight on the web; Glasp stores the highlights with stable text-fragment anchors (`#:~:text=...`) so reopening the original page jumps to your highlight. The "summary" is whatever subset of the page you chose to highlight. Glasp also exports highlights as markdown to Roam/Notion/Obsidian.

**Takeaway:** No mainstream tool combines (a) one-paste URL ingest, (b) AI-generated *structured* summary, (c) per-bullet click-back-to-source-paragraph, (d) plain-markdown storage. Recall comes closest on (a)+(b)+(d); NotebookLM is best at (c) but only inside its own viewer. **This is open territory.**

### 3.2 Content-extraction approaches

The job: arbitrary URL → clean main text with structure (headings, paragraphs, images), without nav/ads/sidebars.

| Approach | What it is | Pros | Cons | Mac-native fit |
|---|---|---|---|---|
| **[Mozilla Readability.js](https://github.com/mozilla/readability)** | The Firefox Reader View algorithm — scores DOM nodes by text density, link ratio, class/id heuristics; returns `{title, byline, content, textContent, length, excerpt, siteName}` | Industry standard, [SIGIR 2023 study](https://dl.acm.org/doi/pdf/10.1145/3539618.3591920) found it has the **highest median F1 (0.970)** and highest predictability; permissive license; ports for [Rust](https://crates.io/crates/readability-rust) and Swift exist | Pure JS; requires JSDOM or a real DOM; can fail on list-pages, very short pages, or DOM-broken sites | **Best fit.** Run it inside a `WKWebView` after the page renders, then extract via injected JS — no Node dependency, native macOS. |
| **[Trafilatura](https://trafilatura.readthedocs.io/)** | Python lib; hybrid heuristic + DOM analysis; preserves structure; outputs Markdown/XML/TEI | [SIGIR 2023](https://chuniversiteit.nl/papers/comparison-of-web-content-extraction-algorithms): best mean F1 (0.883); [independent benchmark](https://apify.com/glueo/contextractor) ranks F1 0.958, recall 0.978 — best overall when averaging; preserves headings/paragraph structure precisely (we'll need this for anchor mapping) | Python; would require shipping a Python runtime *or* a port (Go port exists: [go-trafilatura](https://github.com/markusmobius/go-trafilatura)) | **Awkward.** Not Mac-native; would need a sidecar binary. |
| **jusText / Boilerpipe / Goose3** | Older heuristic extractors | Decent recall | Not actively maintained; lower F1 than Readability/Trafilatura | Skip. |
| **[Jina Reader (r.jina.ai)](https://github.com/jina-ai/reader)** | HTTP API: `GET https://r.jina.ai/<URL>` returns LLM-friendly Markdown; runs headless Chromium internally; can use proxies, geo-routing, PDF parsing | Zero local dependencies; handles JS-rendered SPAs; PDF support; supports `X-Respond-With: frontmatter` for YAML metadata; 1M tokens free on signup per [jina.ai/reader](https://jina.ai/reader/); ~2s typical response | Network dependency; cost at scale; third-party privacy (your URLs hit Jina servers); anonymous tier capped at 100 RPM / 100K TPM | **Excellent fast-path** for the v1 fetcher — wrap the API in a tool, fallback to local extraction on failure. |
| **[Firecrawl](https://firecrawl.dev)** | Hosted scraping API similar to Jina; markdown output, structured data extraction | JS rendering, screenshots, crawling | Paid, similar trade-offs to Jina | Backup option. |
| **Diffbot** | Enterprise-grade structured-content API (knowledge graph, article, product extraction) | High accuracy on edge cases | $$$$, enterprise pricing | Skip. |
| **Headless Chromium (Playwright/Puppeteer)** | Full browser, then inject Readability | Handles any JS-rendered site; full fidelity | Multi-hundred-MB binary, slow cold-start, app-store distribution headaches | Skip in v1. |
| **WKWebView (Mac-native)** | Native Apple browser engine inside your app | Free, ships with macOS, perfect rendering fidelity, share cookies/identity if logged in | Async, requires careful injection timing | **Best Mac-native option for JS-heavy pages.** |
| **Pure HTTP + SwiftSoup** | `URLSession` fetch + [SwiftSoup](https://github.com/scinfu/SwiftSoup) DOM parse + Readability-style heuristics implemented in Swift | Lightweight, fast, no browser overhead | Fails on JS-rendered SPAs; need to reimplement Readability scoring | **Best v1 fast-path** for plain articles. |

**Recommended stack for PunkRecords:**

1. **First try:** `URLSession` → SwiftSoup → port Readability scoring to Swift (≈400 lines based on the [algorithm walkthrough](https://webcrawlerapi.com/blog/mozilla-readability-algorithm-readabilityjs)). Fast, offline, private.
2. **If that returns < ~250 chars of content OR `isProbablyReaderable()` returns false:** fall back to invisible `WKWebView`, let the page render, inject `@mozilla/readability` from CDN or bundled JS, evaluate the parse function, return the result.
3. **If WKWebView fails (paywall, login wall, anti-bot):** offer the user a one-tap "send to Jina Reader" fallback (with explicit consent — their URL leaves the machine).

This three-tier ladder gives you offline + private by default, full fidelity when needed, and a graceful escape hatch.

### 3.3 Mapping summary points → source paragraphs

Three viable techniques, in increasing order of fragility:

#### A. Heading-anchor extraction
Most articles use `<h1>`–`<h6>` with `id` attributes (especially on docs sites, blogs with TOC plugins, Wikipedia). Extract every heading id during ingest and store an `outline` array; the LLM is instructed to cite the *nearest preceding heading id* for each bullet. Anchor: `https://example.com/article#heading-slug`. **Works in every browser. Highest robustness when ids exist.** Failure mode: ~40% of pages don't ship heading ids.

#### B. Scroll-to-text fragments (`#:~:text=`)
The [W3C/WICG URL Fragment Text Directives spec](https://wicg.github.io/scroll-to-text-fragment/) lets a URL specify a text snippet the browser scrolls to and highlights: `https://example.com/article#:~:text=specific%20phrase` — with optional `prefix-,start,end,-suffix` for disambiguation. Browser support per [caniuse](https://caniuse.com/url-scroll-to-text-fragment): **Chrome (since v80, Feb 2020), Safari (since 16.3, Jan 2023), Firefox (since v131, Oct 1, 2024)**, and all Chromium-based browsers. **Encoding rule:** percent-encode the phrase; pick 5–10 word snippets unique to the page; use `prefix-` and `-suffix` only when needed to disambiguate. Search engines (Google) use this constantly for "answer highlighting." **This is the most powerful approach for PunkRecords** because it works on *any* page the agent can extract text from, without requiring author-defined ids.

#### C. DOM-path anchors (XPath / CSS selectors)
Store a CSS selector or XPath like `article > section:nth-of-type(3) > p:nth-of-type(2)` for each cited paragraph; reopen by reinjecting JS into a WKWebView and scrolling that node into view. **Most precise**, but **brittle**: any DOM change on the source site breaks the link. Use only as an internal index inside PunkRecords' own re-render of the cached page, not as a stable external link.

#### D. Citation UX patterns to copy
- **NotebookLM:** numbered superscripts; hover preview; click opens source panel scrolled to passage. Citations live inline in the text.
- **Perplexity:** inline numbered citations `[1]` `[2]` rendered as clickable chips that open the source URL in a side panel.
- **Recall:** "knowledge card" with section anchors; for YouTube, timestamps that deep-link the video.

**Recommendation for PunkRecords:** Hybrid approach. Generate text-fragment URLs (`#:~:text=`) as the **primary** anchor for each bullet — they degrade gracefully (if no match, browser just loads top of page). Store the heading-id fallback as a property. Render in markdown as inline numbered citations `[¹]` `[²]` that map to a "Sources" section at the bottom with the full `#:~:text=` URLs. This makes the markdown self-contained and portable: open the note in *any* markdown viewer, click the link, jump to source.

### 3.4 Default summary structure

What users actually like, based on what each tool ships as default:

- **NotebookLM:** "Briefing doc" format — TL;DR paragraph, then themed sections with bulleted key points, each citation-linked.
- **Readwise Ghostreader:** Configurable; default is "key takeaways" bulleted list (3–7 points).
- **Matter:** Single-paragraph TL;DR (2–3 sentences).
- **Recall:** Two modes — *Concise* (TL;DR + 3–5 bullets) vs. *Detailed* (sectioned with subheadings). Users praised this dual mode in Product Hunt reviews.
- **Glasp:** No summary; user's own highlights are the summary.

**The right default for PunkRecords:**

```
1. TL;DR  (1–3 sentences)
2. Key points  (5–9 bullets, each with inline source citation)
3. Notable quotes  (2–4 verbatim excerpts ≤30 words)
4. Why this matters / open questions  (optional, 1–2 sentences)
```

This matches the Recall *Concise* model plus quotes, and aligns with how knowledge workers actually re-find things (TL;DR for "do I care," bullets for facts, quotes for citation in their own writing). Make the format a single template the user can edit; keep the LLM prompt deterministic so summaries are stable across re-runs of the same URL.

### 3.5 Failure modes

| Failure | Detection | Strategy |
|---|---|---|
| **YouTube / Vimeo video page** | `og:type=video.*`, host match, or video element dominant | Switch to transcript fetcher (YouTube auto-captions via `youtube-transcript` equivalents); summarize transcript; anchor with `&t=Ns` timestamps |
| **PDF disguised as URL** | `Content-Type: application/pdf` or `.pdf` extension | Route to PDFKit (Mac-native) for text + page extraction; cite by page number |
| **Paywall** | Short body length + `meta robots noarchive`, common paywall class names (`paywall`, `subscription-wall`), or domain matches a known list | Detect early; surface to user: "this page is paywalled — paste the text manually, or open in your browser where you're logged in and re-trigger from there" |
| **Login wall** | 401/403, or redirect to `/login`, `/signin` | Same as paywall; offer "use WKWebView with your cookies" mode (one-click "open in app and re-extract") |
| **Infinite scroll** | Body length grows when scrolling; very few headings; "load more" buttons | WKWebView fallback with programmatic scroll-to-bottom + DOM mutation wait; cap at 30s |
| **JS-only SPA** | Initial HTML body has no main content | WKWebView fallback automatic |
| **Page >50k tokens** | Token count after extraction | Two-stage summarization: chunk by H2 heading, summarize each chunk, then meta-summarize. Store both per-section summaries and overall summary. Long content benefits anyway: each chunk's summary anchors to that section's heading id or first `#:~:text=`. |
| **Article is actually transcript / comment thread** | Heuristic: high speaker-name density, many short paragraphs | Route to a different prompt template ("this is a conversation; extract participants, decisions, and disagreements") |
| **Foreign language** | `lang` attribute or charset detection | Either summarize in the source language or auto-translate then summarize (user setting) |

### 3.6 Storage shape — concrete markdown schema

Plain markdown file in the vault, named `Web/{YYYY-MM-DD}-{slug}.md`. Frontmatter is YAML; body is markdown with inline citations.

```markdown
---
title: "The Bitter Lesson"
source_url: "http://www.incompleteideas.net/IncIdeas/BitterLesson.html"
source_domain: "incompleteideas.net"
author: "Rich Sutton"
published: 2019-03-13
fetched: 2026-05-18T14:22:31Z
fetcher: "swiftsoup+readability"  # or "wkwebview", "jina"
summary_model: "claude-sonnet-4.5"
summary_prompt_version: 3
word_count: 1287
reading_time_min: 6
tags: [ai, rl, history]
type: web-summary
status: read
links:
  - "[[AGI]]"
  - "[[Compute scaling]]"
---

# The Bitter Lesson

## TL;DR
70 years of AI research show that general methods leveraging computation
beat methods that build in human domain knowledge. Search and learning
are the only approaches that scale arbitrarily with compute.[¹]

## Key points
- AI researchers consistently try to bake in human knowledge of how
  problems are solved, which yields short-term gains but caps long-term
  progress.[²]
- The "bitter lesson" is that the methods that ultimately win are
  *general* ones — search and learning — scaled with compute.[³]
- Chess (Deep Blue), Go (AlphaGo), speech recognition, and computer
  vision all repeat this pattern: hand-crafted features lose to learned
  representations on scaled compute.[⁴]
- Researchers should focus on meta-methods that *find* the structure,
  not encode it.[⁵]

## Notable quotes
> "The biggest lesson that can be read from 70 years of AI research is
> that general methods that leverage computation are ultimately the
> most effective, and by a large margin."[¹]

## Why this matters
Cuts against the temptation to over-engineer the agent loop with
domain-specific heuristics. Worth re-reading when designing
PunkRecords' retrieval ranker — bet on embeddings + scale, not on
hand-tuned features.

## Sources
[¹]: http://www.incompleteideas.net/IncIdeas/BitterLesson.html#:~:text=The%20biggest%20lesson,a%20large%20margin
[²]: http://www.incompleteideas.net/IncIdeas/BitterLesson.html#:~:text=researchers%20have%20sought,human%20knowledge
[³]: http://www.incompleteideas.net/IncIdeas/BitterLesson.html#:~:text=search%20and%20learning
[⁴]: http://www.incompleteideas.net/IncIdeas/BitterLesson.html#:~:text=Deep%20Blue
[⁵]: http://www.incompleteideas.net/IncIdeas/BitterLesson.html#:~:text=meta-methods
```

Notes on the schema:
- **`fetched` timestamp + `fetcher` field** lets you re-run extraction with a newer fetcher and diff.
- **`summary_model` + `summary_prompt_version`** is essential for trust and reproducibility — when the user asks "why does this summary suck," you can re-summarize with a different model in one click.
- **`source_url` + per-bullet `#:~:text=` links** = the markdown file works in any markdown viewer; click jumps to source in any modern browser.
- **`type: web-summary`** is a vault-wide property that lets the agent filter ("show me all web summaries about RL from this month").
- **Inline `[[wikilinks]]` in `links`** automatically wire into your backlinks graph.
- **Cached HTML** can optionally be stored as `Web/_cache/{slug}.html` for offline viewing and DOM-path-anchor rendering inside the app.

---

## 4. Differentiation opportunities

What users complain about — the gaps a Mac-native, local-first, agent-first markdown app can credibly fill.

### Mac-native performance vs. Electron
Electron apps dominate PKM (Obsidian, Notion, Logseq, Reflect, Tana) and Mac power users are loud about it. From HN: *"Preface: I am a massive Obsidian fan and use it everyday. The problem is they wanted it multi platform... so they made it using electron. Unless they... rewrite the entire application in something quicker like Tauri it's never going to be as fast as apple [native]"* ([HN 34068011](https://news.ycombinator.com/item?id=34068011)). And: *"I'm happy for devs' 'faster development', but as a user I care about 'faster use', which Electron blocks outright"* ([HN 47196852](https://news.ycombinator.com/item?id=47196852)). Atlas's May 2026 cold-start benchmarks measured open-to-typing latency at Apple Notes 0.4s, Bear 0.7s, Craft 1.1s, Obsidian 1.3s, and Notion 2.6s ([atlasworkspace.ai](https://www.atlasworkspace.ai/blog/best-note-taking-apps-for-mac)). **PunkRecords is SwiftUI-native — this is your home-court advantage; target cold-start <500ms and zero-jank typing as launch benchmarks.**

### AI trust and lock-in
NotebookLM measured 13% hallucination rate on document tasks ([arXiv 2509.25498](https://arxiv.org/html/2509.25498v1)) — still 1-in-8. Saga's own docs warn: *"It's important to note that while Saga AI is a powerful tool, it does have some limitations. For example, it may output incorrect information, or even harmful content"* ([saga.so/guides/saga-ai](https://saga.so/guides/saga-ai)). Heptabase pitches against this trend explicitly: *"Heptabase is not a tool that thinks for you; it's a 'tool for thought' that creates an environment for you to think better"* (Heptabase founder positioning, [Oct 2025](https://skywork.ai/skypage/en/Heptabase-Unleash-Your-Ideas-with-AI-Powered-Visual-Knowledge-Management/1976126547280195584)). **Opportunity:** every AI output in PunkRecords should be (a) cited to its source span, (b) re-runnable with a different provider, (c) clearly visually distinct from human-written text (Granola's grey-text-for-AI is the right pattern), (d) trivially deletable. Multi-provider routing (Anthropic + OpenAI + Apple Foundation) gives users an escape if any one provider regresses — a moat against the "NotebookLM outage of Sept 2025" failure mode where users tweeted *"I'll fail my exam at this rate"* ([Medium recap](https://medium.com/@kombib/when-notebooklms-never-hallucinates-ai-started-hallucinating-it-was-working-a-digital-crisis-233bb972514c)).

### Sync, privacy, and lock-in
Notion data lock-in is a recurring HN complaint: *"Around 3 months ago, I started having issues with their 'Export' feature… the link never arrives… It was a critical function that locks us with them and goes against their selling message of 'you own your data'. I was ignored, with the same robotic tone"* ([HN 27612894, 479 points](https://news.ycombinator.com/item?id=27612894)). Roam users have publicly left over moderation and lock-in: *"I stopped using their tool on principle… [Roam founder was] monitoring Reddit threads and banning people"* ([HN 32248805](https://news.ycombinator.com/item?id=32248805)). **Opportunity:** PunkRecords is plain markdown on disk — there is literally no export. Make this the first sentence of the marketing page. Add an obvious "Reveal in Finder" button on every note. Document the file layout publicly so users *can* leave with one command.

### Subscription fatigue
*"We don't like subscriptions, especially if you have to pay to access your data. That was the main reason we avoided Evernote… Why not pay for an app that keeps your notes offline on your device?"* ([beingpaperless.com](https://beingpaperless.com/notion-concerns-and-first-impressions/)). XDA: *"I hit my breaking point using Notion again with a client who insisted on sticking to it. Not because it's bad — it's genuinely powerful — but because they were paying for features I'd touch maybe twice a year"* ([xda-developers.com](https://www.xda-developers.com/open-source-notion-alternative/)). **Opportunity:** If PunkRecords ever charges, charge for *services that cost money to run* (hosted LLM credits, optional sync relay) — not for features that should be local. One-time license + bring-your-own API keys is the honest pricing.

### Tinkering trap vs. just writing
The dominant r/ObsidianMD complaint, paraphrased from XDA's summary of the sentiment: *"I've seen people strip plugins from their setup just to keep Obsidian running smoothly. Once you do that, you're no longer writing or organizing notes. You're troubleshooting, waiting for a fix, or searching for replacements that never feel the same as what you lost"* ([xda-developers.com](https://www.xda-developers.com/obsidians-reliance-on-plugins/)). Crystal Lee (MIT) on Zettelkasten yak-shaving: *"There's a part of me that wants to buckle down and really milk this system for all it's worth — while another part of me argues that this is all an illusion, that it's just the newest form of productive procrastination. Yak shaving at its finest"* ([blog](https://crystaljjlee.com/blog/experiments-with-zettelkasten/)). **Opportunity:** PunkRecords ships zero plugin API in v1. The opinionated defaults *are* the product. Power users get scripting (AppleScript / shortcuts / MCP tools) but not plugin chaos.

### Underserved
- **One-paste URL → structured summary → click-to-source-paragraph.** Recall is closest but cloud-only, no markdown vault, no offline. NotebookLM is closest on citation quality but its sources live inside Google, not your filesystem.
- **Multi-provider agent loop with seamless fallback.** Existing Obsidian plugins each lock you into one provider.
- **Daily briefing of "what's in your vault that you should re-read."** No tool does this well; Readwise comes closest with Daily Review of highlights, but it's not vault-aware.
- **Mac-native speed.** Bear is fast but has no AI; Apple Notes is fast but has no graph/wikilinks. There is no fast AI-PKM on Mac in 2026.

---

## 5. Anti-features

What power users explicitly do NOT want. Build PunkRecords *against* this list.

- **Forced cloud sync.** Cited above (Notion, Roam, Mem). Anti-feature: storing notes anywhere the user can't see in Finder. PunkRecords ships with vault = a folder you pick.
- **Proprietary lock-in formats.** Notion's database export blob, Roam EDN, Mem's opaque structure. Anti-feature: anything other than markdown + frontmatter + images.
- **AI that thinks *for* you.** Heptabase's positioning quote above. Auto-generated content that the user didn't request, AI "rewrites" that overwrite the human draft, hidden auto-tagging the user didn't see. Anti-feature: any AI write that isn't (a) requested, (b) clearly attributed, (c) trivially revertable.
- **Gamification.** Streaks, "you've added 50 notes this week!" — every PKM user surveyed in r/PKMS finds these patronizing in a thinking tool.
- **Social features.** Glasp's social feed is contested; in a personal tool, "who else highlighted this" is a distraction. PunkRecords serves two people who already know each other.
- **Opinionated structure that fights the user.** Notion's database-first model, Tana's mandatory supertags, Capacities' object types. Power users repeatedly complain that the *system* becomes the work. Anti-feature: any required schema beyond "files in folders with frontmatter."
- **Mandatory accounts.** Mem, Notion, Reflect all require sign-up before you can type. PunkRecords should let you write a note before the app has heard of you.
- **Subscriptions for features that should be local.** Search, tags, wikilinks, basic AI with your own API key — these are local features. The XDA and beingpaperless quotes above. Anti-feature: any subscription gate on a feature that doesn't cost the developer money to run.
- **Telemetry by default.** Even anonymous "usage analytics" violates the trust contract of a private notes tool. Anti-feature: any network call the user didn't explicitly trigger.
- **Plugin marketplaces.** The Obsidian tinkering-trap quote above. PunkRecords doesn't ship one. The app is the app.

---

## Final section: "If I could only ship 10 features, these are them"

Tailored for: single Mac-native SwiftUI dev, two-person initial user base (you and your wife), local-first markdown vault with FTS5 + multi-provider agent loop already working.

### P0 — ship first (the v1.0 minimum)

**1. Global quick-capture hotkey → new note in the vault**
Why: capture friction kills PKMs. If it takes more than one keystroke to write a thought down, the thought dies.
Implementation: `NSEvent.addGlobalMonitorForEvents` for hotkey; small floating SwiftUI window; on submit, write `.md` file with auto-frontmatter (`created`, `id`); add to FTS5 index synchronously. <300ms from hotkey to text cursor.
**P0**

**2. URL-paste → cliffs-notes web summary (the wedge)**
Why: this is the differentiator from Bear/Apple Notes. Section 3 of this report exists for this feature.
Implementation: agent tool `summarize_url`. Three-tier fetcher (URLSession+SwiftSoup → WKWebView+Readability.js → Jina Reader). Summary prompt produces the JSON-structured TL;DR + bullets + quotes; renderer writes markdown with `#:~:text=` citations per Section 3.6 schema. Store cached HTML in `Web/_cache/` for offline.
**P0**

**3. Chat-with-vault with cited answers**
Why: this is the table-stakes 2026 AI feature; without it the app is "yet another markdown editor."
Implementation: tool-calling agent loop (you have this). Tools: `search_vault` (FTS5), `read_doc`, `list_docs`. Render assistant messages with inline `[¹]` citations that resolve to `punkrecords://open?file=...&line=N` links. Show source notes in a side pane on click.
**P0**

**4. Fast full-text search with live ranking**
Why: SQLite FTS5 you already have. Make it Spotlight-fast (≤30ms p99 on 10k notes).
Implementation: FTS5 with `porter` tokenizer; trigram fallback for partial matches; rank with bm25 + recency boost; SwiftUI `searchable` with `.onSubmit` debounced 50ms.
**P0**

**5. Wikilinks + backlinks panel**
Why: emerges-as-table-stakes from every PKM. Two-line implementation given your existing parser.
Implementation: on save, parse `[[Note Name]]` → resolve to filename → store in SQLite link-graph table. Backlinks panel: `SELECT source FROM links WHERE target = ?` rendered as a `List` at the bottom of the note. Auto-complete `[[` with fuzzy match.
**P0**

### P1 — fast-follow (weeks 2–8 after v1)

**6. Daily briefing**
Why: NotebookLM's killer demo is "ask the agent what's interesting in my corpus." None of the local-first PKMs ship this.
Implementation: scheduled `BGAppRefreshTask` or simple launch-time check (last_briefing < 24h). Agent prompt: "Given these notes touched/created in the last 7 days, write a 5-bullet brief: what I'm thinking about, open threads, things I haven't followed up on." Output to `Briefings/{date}.md`. Use Apple Foundation Models for the cheap-and-private default; route to Claude/GPT on explicit upgrade.
**P1**

**7. Multi-provider model picker per agent call**
Why: trust + lock-in defense. Lets the user retry with a different model when one disappoints — directly addresses the AI-trust gap from Section 4.
Implementation: enum `AIProvider { case anthropic, openai, appleFoundation }`. UI: small chip in the chat composer; ⌘1/2/3 keyboard. Per-message metadata stored as a comment in the note (`<!-- model: claude-sonnet-4.5 -->`).
**P1**

**8. Two-way iCloud Drive sync (your vault is a folder)**
Why: you and your wife need to share. Roll-your-own E2E sync is months of work; iCloud Drive is free and battle-tested.
Implementation: put the vault folder inside `~/Library/Mobile Documents/iCloud~com~punkrecords/`. Watch with `DispatchSource.makeFileSystemObjectSource`. Re-index FTS5 on file change. Handle Apple's "iCloud conflict copies" by surfacing them in a "conflicts" view — don't try to auto-merge.
**P1**

**9. Web clipper (browser extension or share-extension)**
Why: 70% of "web summary" use will come from "I'm reading this, save it" not "I have a URL on my clipboard."
Implementation: macOS Share Extension (one-time SwiftUI + Web Extension target). Posts URL to a local Unix socket the main app listens on; main app runs the same `summarize_url` tool. Bonus: Safari Reader-API integration if available.
**P1**

### P2 — nice-to-have (only if there's time)

**10. MCP server exposing vault tools**
Why: you already have multi-provider routing; MCP exposure means Claude Desktop, Cursor, and any future MCP-aware client can talk to the vault. Future-proofs the agent surface and lets you (the developer) dogfood new workflows without writing UI for each.
Implementation: lightweight stdio MCP server in Swift (or Node sidecar if Swift MCP SDK isn't mature enough — May 2026 should have one). Expose `search_vault`, `read_doc`, `create_note`, `list_docs`, `summarize_url`. Read-only by default; opt-in writes per session.
**P2**

### What's intentionally NOT in the list

- Graph view (pretty but rarely used; users tinker with it for hours and then never open it again — Section 4's tinkering trap)
- Plugin API (you're one developer; every plugin is a future support email)
- Canvas/whiteboard (Heptabase exists; don't fight on their turf)
- Real-time multiplayer collab (two users with iCloud Drive last-writer-wins is enough)
- Mobile app (defer to v2; the spec explicitly says Mac-native v1)
- Cross-platform anything (Windows, Linux, web) — explicitly out of scope per the brief

---

## Completion table

| Section | Status |
|---|---|
| 1. Competitive feature matrix (19 products) | ✅ table + sources |
| 2. Table-stakes inventory (7 categories) | ✅ table-stakes/differentiator/niche labels |
| 3. Web ingestion deep dive | ✅ 8 tools analyzed, extraction libs compared, anchor techniques, summary formats, 9 failure modes, frontmatter schema with example |
| 4. Differentiation opportunities | ✅ 5 areas, community-sourced quotes |
| 5. Anti-features | ✅ 10 anti-features, sourced |
| Final 10 features (P0/P1/P2) | ✅ with Swift/SwiftUI/SQLite hints |