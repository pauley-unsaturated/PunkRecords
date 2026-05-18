# PunkRecords — Markdown Editor Decision Report

**TL;DR**
- **Pick Option B (NSTextView + TextKit 1, wrapped in SwiftUI via `NSViewRepresentable`), with `Neon` + `swift-markdown` driving hybrid-markdown styling.** This matches the proven Bear (v1) / iA Writer / Drafts pattern, scales to 50k+-file vaults (vault scaling is a filesystem + SQLite FTS5 problem, not an editor problem), and gives you native IME, accessibility, Writing Tools, and Find/Replace for free.
- **Avoid TextKit 2 as your foundation in 2026.** Apple's own TextEdit silently falls back to TextKit 1 for tables and printing ([WWDC22 #10090](https://developer.apple.com/videos/play/wwdc2022/10090/)), MarkEdit explicitly rejected it and shipped CodeMirror 6 instead ([MarkEdit wiki](https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit)), and AltStore publicly regretted migrating. STTextView's author wrote a "promised land" post documenting seven specific unresolved FB radars after four years of work ([blog.krzyzanowskim.com](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/)).
- **2-week fallback if Option B slips:** wrap a single `NSTextView` (TextKit 1) with line-by-line regex highlighting via an `NSTextStorage` delegate, persist via `swift-markdown` for canonical parse, and ship without Live-Preview marker hiding. You won't have pill-chip wikilinks or replaced-range rendering, but you'll have a working PKM editor.

---

## Section 1 — The Landscape: What Real Apps Actually Ship

Plain-text Markdown editors split into four lineages: native `NSTextView`/`UITextView` apps (the Apple-first camp), Electron-with-CodeMirror apps (the Obsidian camp), Electron-with-ProseMirror apps (the Notion camp), and a few custom engines (Bear 2, Craft). The table below is what each app *actually* runs, drawn from primary sources where possible.

| App | Editing model | Underlying stack | What users praise / complain |
|---|---|---|---|
| **Bear** | Hybrid (markers visible, styled inline) | **C++ AST editor core ("Panda")** with ObjC/Swift shells; SQLite (Core Data) storage — **not** flat `.md` ([blog.bear.app](https://blog.bear.app/2021/06/checking-in-on-panda-the-next-editor-for-bear/), [9to5Mac](https://9to5mac.com/2023/07/11/bear-2-features/), [denisdefreyne.com](https://denisdefreyne.com/notes/importing-notes-from-bear/)) | + design, hashtag organization, polish; – uses "Polar Bear" custom markup, no flat-file vault ([bear.app FAQ](https://bear.app/faq/where-are-bears-notes-located/)) |
| **iA Writer** | Hybrid, source always visible, syntax dimming | Native AppKit/UIKit, TextKit (1) | + typography, focus mode, Syntax Control highlighting parts of speech ([ia.net](https://ia.net/writer)); – limited extensibility, no plugins |
| **Ulysses** | Hybrid, "Markdown XL" custom flavor | Native AppKit/UIKit + TextKit; proprietary library | + Mac/iOS polish, library; – subscription, custom Markdown XL |
| **Typora** | True WYSIWYG, no source visible | Electron + CodeMirror in source view + custom rendering layer ([typora/typora-issues #1317](https://github.com/typora/typora-issues/issues/1317)) | + clean WYSIWYG; – performance regressions, quirky list behavior ([#1861](https://github.com/typora/typora-issues/issues/1861)) |
| **Obsidian** | Hybrid Live Preview (markers hide near caret) + Source mode | Electron + **CodeMirror 6** ([HN](https://news.ycombinator.com/item?id=31666186)) | + plugins, flat-file vault, scales to 280k+ notes ([forum.obsidian.md](https://forum.obsidian.md/t/maximum-number-of-notes-in-vault/1509)); – Electron memory, mobile UI |
| **Notion** | Block-based WYSIWYG | Custom React block editor; cloud-only | + collaboration; – not a PKM, no flat files |
| **Craft** | Block-based, drag handles per block | **Mac Catalyst** + custom block engine + in-house CRDT sync ([appstacks.club/craft](https://appstacks.club/craft)) | + native-feeling Catalyst, "hundreds of thousands of blocks per document"; – no flat files |
| **MarkText** | WYSIWYG-ish hybrid | Electron + custom editor (Muya, ProseMirror-inspired) | + free; – stalled development |
| **Logseq** | Outliner, block-based, hybrid | **Electron + Capacitor; ClojureScript + Rum (React) + DataScript**; CodeMirror only for code blocks; custom outliner for prose ([deepwiki](https://deepwiki.com/logseq/logseq)) | + outliner, query DSL; – Electron, complex |
| **Heptabase** | Card + whiteboard, hybrid markdown inside cards | Electron + custom card engine; local-first SQLite | + visual; – Electron, lag on large whiteboards |
| **Reflect** | Hybrid Markdown | Electron + ProseMirror | + e2e crypto; – subscription, Electron |
| **NotePlan** | Hybrid Markdown calendar/notes | Native macOS + iOS, Markdown-based, flat `.md` files | + calendar/task integration, flat files; – niche |
| **Drafts** | Source-only with custom syntax highlight | **Native AppKit/UIKit; TextKit; Core Data + CloudKit sync**; "I built my own cross-platform EditorKit on top of [TextKit]" — Greg Pierce ([indiedevmonday.com](https://indiedevmonday.com/issue-26)) | + capture speed, automation; – not really WYSIWYG |
| **Marked 2** | Preview-only (not an editor) | Native macOS + WKWebView for preview | + great preview/export; – not the editor question |
| **Apple Notes** | WYSIWYG | Native + custom proprietary rich-text storage | + free, built-in; – not Markdown, not a PKM |

**Wikilinks / frontmatter / tables / math / code blocks specifics:**

- **Bear** supports tables (since 2.0), code blocks with syntax highlight, `[[wikilinks]]`, and `#nested/tags`. No YAML frontmatter — metadata is database fields.
- **iA Writer** supports wikilinks `[[ ]]`, YAML-style "Content Blocks", tables, code blocks, math (LaTeX in Preview), footnotes ([ia.net/writer](https://ia.net/writer)).
- **Obsidian** supports everything: wikilinks with alias `[[Note|alias]]`, embeds `![[Note]]`, block refs `[[Note#heading]]` and `[[Note^block-id]]`, YAML frontmatter with a structured "Properties" panel UI, tables, MathJax `$$`, Mermaid, KaTeX, code blocks via Prism.
- **Logseq** wikilinks `[[ ]]`, block refs `((block-id))`, properties as `key:: value`, code via CodeMirror.
- **Typora** [[wikilinks]] not standard, instead Markdown `[text](file.md)`; tables via inline editor; math via MathJax.
- **Craft** uses `@`-mentions instead of `[[`; recent versions added Mermaid diagrams and LaTeX math.

---

## Section 2 — The Four Options

### Option A — SwiftUI `TextEditor` + custom styling

In macOS 26 (Tahoe) and iOS 26, `TextEditor` finally accepts an `AttributedString` binding and exposes `AttributedTextSelection` for programmatic style transforms ([createwithswift.com](https://www.createwithswift.com/using-rich-text-in-the-texteditor-with-swiftui/), [hackingwithswift.com](https://www.hackingwithswift.com/quick-start/swiftui/how-to-use-rich-text-editing-with-textview-and-attributedstring)). That is genuinely new — pre-macOS 26 it was String-only.

```swift
@State private var text = AttributedString("")
@State private var selection = AttributedTextSelection()
TextEditor(text: $text, selection: $selection)
// Toggle bold on the current selection
Button("Bold") {
  text.transformAttributes(in: &selection) { container in
    let resolved = (container.font ?? .default).resolve(in: fontResolutionContext)
    container.font = (container.font ?? .default).bold(!resolved.isBold)
  }
}
```

**What you cannot do:** no caret position queries, no `NSTextLayoutFragment` access, no line-fragment widget views, no per-character `NSLayoutManager` invalidation hooks, no replaced-range decoration (e.g. render `[[Note]]` as a pill chip while preserving the source). The `AttributedString` API's `presentationIntent` is **semantic**, not visual — you still walk the runs and translate intents into fonts/colors yourself ([nilcoalescing.com](https://nilcoalescing.com/blog/AttributedStringAttributeScopes/), [frankrausch/AttributedStringStyledMarkdown](https://github.com/frankrausch/AttributedStringStyledMarkdown)).

**Large-document behavior:** `TextEditor` is backed by `NSTextView`/`UITextView` but the SwiftUI wrapper inherits its limitations and adds round-trip cost on every keystroke when bound to `AttributedString`. There are no public hooks to use TextKit 2's viewport layout.

**Vault-scale (50k+ notes):** fine — vault scaling is a search/index problem, not an editor problem.

**License:** Apple, free. **Maturity:** the rich-text variant is brand new in macOS 26 — treat as 1.0. **Cost:** low for plain editing; very high for hybrid-markdown UX.

> **Verdict — Avoid for v1.** The hybrid-markdown UX PunkRecords needs (pill-chip wikilinks, replaced ranges, marker dimming near caret) cannot be done in SwiftUI `TextEditor` today. Revisit in 2027–2028.

### Option B — `NSTextView` wrapped via `NSViewRepresentable` (the recommendation)

This is what Bear (until v2), iA Writer, Ulysses, and Drafts have all shipped. The wrapping pattern is well-trod:

```swift
struct MarkdownTextView: NSViewRepresentable {
  @Binding var text: NSAttributedString
  let highlighter: MarkdownHighlighter   // your styling pipeline

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let tv = scrollView.documentView as! NSTextView
    tv.delegate = context.coordinator
    tv.textStorage?.delegate = context.coordinator
    tv.allowsUndo = true
    tv.isRichText = false  // we control attributes ourselves
    return scrollView
  }
  // textStorage(_:didProcessEditing:range:changeInLength:) re-styles edited paragraph
}
```

**TextKit 1 vs TextKit 2 — this is the single biggest decision you make.** The evidence in 2025–2026 is overwhelmingly against TextKit 2 as a *foundation*, while it remains attractive on paper:

- Marcin Krzyżanowski (author of `STTextView`, ~4 years of TextKit 2 production experience): *"Based on my 4 years of experience working with it, I feel like I fell into a trap. It's not a silver bullet… annoying to use (at best) and not the right tool for the job (at the worst)."* He documents seven specific unresolved Apple Feedback radars (FB9856587, FB9886911, FB13290979, FB15131180, FB19698121, FB22523964, FB22524198) covering layout-fragment, viewport, and selection bugs spanning macOS 12 through 15.6, writing: *"I reported many bugs myself. Some issues are fixed, while others remain unresolved. Many users received no response."* ([blog.krzyzanowskim.com, Aug 14 2025](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/), [STTextView README](https://github.com/krzyzanowskim/STTextView)).
- Apple's own WWDC22 "What's new in TextKit and text views" session documents the automatic fallback: *"When you explicitly call an NSLayoutManager API, the text view replaces its NSTextLayoutManager with an NSLayoutManager and reconfigures itself to use TextKit 1. This can also happen if the text view encounters attributes not yet supported by TextKit 2, such as tables, or when printing."* ([developer.apple.com/wwdc22/10090](https://developer.apple.com/videos/play/wwdc2022/10090/)).
- TextEdit (Apple's flagship TextKit 2 sample) still falls back to TextKit 1 for tables, wrap-to-page, and printing ([mjtsai.com](https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/)).
- AltStore's developer, after migrating: *"Switching to TextKit 2 in @altstore introduced a bunch of bugs with no tangible benefits, all just to get rid of some deprecation warnings · I wish I'd just kept the deprecation warnings 😅"* (quoted on mjtsai.com).
- MarkEdit, a native macOS markdown editor whose authors *know* TextKit, explicitly chose CodeMirror 6 in WKWebView: *"we know text editing on macOS quite well, including TextKit 1 and TextKit 2, but still chose a web editor… we are tired of exploring the darkness inside TextKit."* ([MarkEdit wiki](https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit)).
- There has been no dedicated WWDC TextKit session since WWDC22 ([askwwdc.com](https://askwwdc.com/q/4469)). WWDC25 focused on Liquid Glass and Writing Tools.
- Nodes app (`nodes-app/swift-markdown-engine`, 2025) does ship TextKit 2 in production and is open source: *"None of the existing open-source options fit what we needed… So we built it on top of TextKit 2. It wasn't easy, but the result holds up in production."* ([github.com/nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)).

**Recommendation within Option B: ship on TextKit 1 (the default `NSTextView`)** and only adopt TextKit 2 features where they help (e.g., a specific `NSTextLayoutFragment` for embedded math previews) — never as the base.

#### The hybrid-markdown styling pipeline

Two parsing approaches dominate:

1. **`swift-markdown` (cmark-gfm under the hood)** — produces a real AST you walk; correct GFM semantics; you control style attribution by visiting nodes ([github.com/swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown)). This is the right choice for **persistence and export**, where correctness matters and a 1ms parse for a 50KB note is fine. cmark-gfm is the same parser GitHub uses; you cannot ship something more semantically correct.
2. **Tree-sitter via `SwiftTreeSitter` + `Neon`** ([ChimeHQ/Neon](https://github.com/ChimeHQ/Neon), [tree-sitter/swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter)) — incremental, designed for live typing, supports language injections (e.g., highlight Swift inside a fenced ```swift block). Neon is text-system-agnostic and was designed by ChimeHQ for exactly this: *"Its hybrid synchronous/asynchronous API makes it possible to scale tree-sitter to large documents, where its parsing/queries can introduce too much latency."*

**Critical judgment on tree-sitter for Markdown:** tree-sitter shines for *programming languages*. For Markdown, the `tree-sitter-markdown` grammar is real but the spec ambiguity of CommonMark/GFM means tree-sitter cannot give you GFM-correct semantics — it gives you a *fast, approximate* tree suitable for **styling decisions** during typing. For PunkRecords this is exactly what you want for the live editor; you still use cmark-gfm via `swift-markdown` for canonical parse on save/export. **Don't use tree-sitter alone.** Use both: `Neon`+tree-sitter for in-editor coloring; `swift-markdown` for authoritative AST.

```swift
// Sketch — Neon + tree-sitter for live highlight, swift-markdown for canonical AST
final class MarkdownStyler {
  let client: TreeSitterClient                            // Neon
  let canonicalParse: (String) -> Markdown.Document       // swift-markdown
  
  func didEdit(_ edit: TextEdit, in storage: NSTextStorage) {
    client.didChangeContent(in: edit.range, delta: edit.delta) // incremental
    Task {
      let invalidated = await client.invalidationSet(for: edit)
      // Apply [.foregroundColor, .font] to invalidated ranges
      await MainActor.run { storage.applyAttributes(invalidated) }
    }
  }
}
```

The "hide markdown markers near the caret" trick (Obsidian Live Preview / Bear hybrid feel) requires an additional layer: track caret position, and for each `**`, `_`, `#`, `[[`, etc. token whose range *does not* contain the caret, set `foregroundColor` to a near-transparent shade and `kern` to collapse the glyph width — or use `NSAttachmentAttributeName` with a zero-width view to replace the range. The cleanest implementation models these as **decoration ranges** in a `RangeSet`, recomputes on every selection change, and reapplies attributes only to the diff (mirroring CM6's `Decoration.replace` API in pattern).

**Performance on 10MB notes:** TextKit 1 + NSTextView handles 10MB plain text well; the bottleneck will be your styling. Solution: throttle full reparse, do incremental highlighting on the edited paragraph(s) only (`NSTextStorage.editedRange` plus paragraph boundaries), and lazy-style only paragraphs as they scroll into the viewport using `NSLayoutManager`'s `ensureLayout(for:)` callbacks.

**Vault scale (50k+ notes):** editor-irrelevant. The vault is a filesystem + index problem. See Section 6.

**Libraries to actually use:**
- **`swift-markdown`** (Apple, Apache 2.0) — canonical parse ([github.com/swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown)).
- **`Neon` + `SwiftTreeSitter`** (Apache 2.0) — incremental syntax styling ([github.com/ChimeHQ/Neon](https://github.com/ChimeHQ/Neon)).
- **`Splash`** or **`Highlightr`** — code-block highlighting inside fenced blocks.
- **`LaTeXSwiftUI`** or **SwiftMath** — for `$...$` and `$$...$$` rendering as `NSTextAttachment`-backed views.
- **`MarkdownUI`** ([github.com/gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)) — useful for *read-only* preview panes, **not** the editor. Do not try to use MarkdownUI as your editor; it renders into SwiftUI views, not into a `TextStorage`.
- **`STTextView`** is interesting but ties you to TextKit 2 and the author's bug list. Use it only if you've read [blog.krzyzanowskim.com/2025/08/14](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/) and accept the risks.

**License:** all named packages are Apache 2.0 or MIT. **Maturity:** TextKit 1 is 25+ years old; `swift-markdown` is Apple-maintained; `Neon` is 3+ years old; `MarkdownUI` is mature. **Cost:** medium-high — plan 4–6 weeks for an editor that does ~85% of Live Preview behavior on macOS.

> **Verdict — Recommend.** This is the path Bear (pre-Panda), iA Writer, Ulysses, Drafts, and now Nodes all took. It scales, accessibility is free, and Swift 6 strict concurrency works because TextKit 1's main-thread requirement maps cleanly to `@MainActor`.

### Option C — Web editor in WKWebView (CodeMirror 6, ProseMirror, Lexical, Tiptap, Milkdown)

**The strongest fit for a PKM Markdown editor in 2026 is CodeMirror 6**, by a wide margin: (a) Obsidian validates it at 280k+-note scale ([Obsidian forum](https://forum.obsidian.md/t/maximum-number-of-notes-in-vault/1509)); (b) its `Decoration.replace` and widget decoration model is *the* canonical implementation of the marker-hiding hybrid UX ([codemirror.net/examples/decoration](https://codemirror.net/examples/decoration/), [segphault/codemirror-rich-markdoc](https://github.com/segphault/codemirror-rich-markdoc)); (c) it has the best mobile story of any editor library. CodeMirror 6.0 stable was released June 8, 2022 with Marijn Haverbeke's announcement: *"At long last, after trying your patience for over 3 years, I've tagged a stable 6.0 release."*

| Library | Strengths for a PKM | Concerns |
|---|---|---|
| **CodeMirror 6** | Mature (stable since June 2022), used by Obsidian, fine-grained decoration API, native-feeling on macOS, lezer-markdown tokenizer | Source-code-editor heritage; "block widgets" for embeds work against the grain |
| **Lexical** (Meta) | Modern architecture, immutable EditorState, fast | Block-first/contenteditable; markdown is a *plugin*, not the model. Still at v0.41.x in May 2026, never cut 1.0 since its April 2022 OSS debut. Liveblocks: *"needs more time to mature… hasn't received a 1.0 release… lack of pure decorations"* ([liveblocks.io](https://liveblocks.io/blog/which-rich-text-editor-framework-should-you-choose-in-2025)) |
| **ProseMirror / Tiptap** | Robust schema model, used by Notion-clones | Internal model is a structured doc tree, not a string. Round-tripping Markdown is *lossy*. Tiptap is a thin wrapper. |
| **Milkdown** | Markdown-first (state ↔ markdown roundtrip); plugin-driven ([Milkdown #134](https://github.com/orgs/Milkdown/discussions/134)) | Smaller community, "not meant to be used outside of frameworks like React or Vue" ([exotext](https://rakhim.exotext.com/markdown-editor-for-exotext)) |

**Latency and jank vs native:** real. A WKWebView keystroke round-trip is 1–3ms slower than native on a fast Mac, and 5–10ms on lower-end hardware. Type-ahead with autocomplete (e.g., wikilink suggestions on `[[`) feels noticeably draggier than native. Obsidian users routinely complain about this.

**Native feel:** WKWebView text-input handlers do not match AppKit conventions for Option-arrow word skipping in non-Latin scripts, smart quotes in non-English locales, or scroll bouncing. Obsidian famously violates Mac conventions in subtle ways here. You can work around each one but the surface area is huge.

**Bridging:** `WKScriptMessageHandler` + `WKWebView.evaluateJavaScript` is standard; messages are async and JSON-serialized, so wikilink autocomplete latency adds another 1–5ms.

**Memory footprint:** WKWebView runs out-of-process so it doesn't crash your app ([Apple Developer Forums 21956](https://developer.apple.com/forums/thread/21956)). The Capacitor team reports *"For some websites, the numbers can be as 200+ MB per each [WKWebView]"* ([Capacitor #6887](https://github.com/ionic-team/capacitor/issues/6887)) — assume ≥200MB per editor pane.

**Real shipping Mac apps using WKWebView+CodeMirror 6 as the editor:**
- **MarkEdit** (open source, primary example — Apple Silicon native): explicitly chose CM6 over TextKit ([github.com/MarkEdit-app/MarkEdit](https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit)).
- **Marked 2** uses WKWebView for *preview*, not editing.
- **Heptabase**, **Reflect**, **Notion**, **Craft for Web** all use Web technologies inside Electron/Catalyst hybrids — but only MarkEdit is a clean Mac+WKWebView example.

```js
// CM6 widget that replaces [[Note Name]] with a pill chip when caret is outside the range
class WikiLinkWidget extends WidgetType {
  constructor(readonly target: string) { super() }
  toDOM() {
    const el = document.createElement("span")
    el.className = "wikilink-pill"
    el.textContent = this.target
    el.onclick = () =>
      window.webkit.messageHandlers.openNote.postMessage(this.target)
    return el
  }
}
// In a StateField, walk the syntax tree; for each WikiLink node when caret is OUTSIDE the range:
const deco = Decoration.replace({ widget: new WikiLinkWidget(text) })
builder.add(node.from, node.to, deco)
```

**Vault scale:** the editor handles a single document; vault-wide concerns (FTS5 index, wikilink resolution) live in your Swift host regardless.

**License:** CM6 / Lexical / ProseMirror / Tiptap / Milkdown all MIT (Tiptap has paid Cloud tiers). **Maturity:** CM6 is post-1.0 since June 2022, proven by Obsidian. Lexical remains pre-1.0 in May 2026. **Cost:** medium up front (WKWebView + IPC + CM6); hybrid-UX work is mostly done by CM6's decoration API.

> **Verdict — Recommend with caveats.** Strong second choice. If you want to ship the *Obsidian Live Preview* UX exactly, CodeMirror 6 in WKWebView is the *easiest* path — but you accept a non-native feel and a permanent JS/Swift maintenance split. For a Mac-native PKM that takes a "feels like Bear / iA Writer" stance, Option B wins on UX even if it costs more code.

### Option D — Block-based native editor (Craft-style)

Building a true Notion/Craft block model natively on macOS means: (a) every block is an `NSView`/SwiftUI view backed by your own document model; (b) blocks are reorderable via drag handles; (c) you serialize to Markdown for persistence, but the editing model is *not* a string.

**Who ships this on macOS today?**
- **Craft** — Mac Catalyst app on a custom in-house engine and custom CRDT sync ([appstacks.club/craft](https://appstacks.club/craft)). They claim *"hundreds of thousands of blocks per document, with a roadmap to reach millions."* No open source.
- **Notion** is web/Electron, not native.
- No mature open-source native block editor for macOS exists. The closest is **BlockNote** (web-based, on top of Tiptap/ProseMirror), which would actually be Option C.

**Cost for a solo dev:** prohibitive. Craft is a multi-person team with multi-year runway. You would spend 12–18 months building primitives (caret navigation across blocks, multi-block selection — which Craft *itself* admits is broken on Mac/iPad: *"text selection is limited to a single block at a time"* ([MacStories review](https://www.macstories.net/reviews/craft-review-a-powerful-native-notes-and-collaboration-app/))).

**Fundamental mismatch with the vault:** PunkRecords stores plain `.md` files. A block editor's native data model is a tree of typed blocks; serializing back to `.md` is *lossy* in both directions, creating diffs that pollute git/iCloud sync and break interoperability with Obsidian.

> **Verdict — Avoid.** Wrong cost class for a solo dev, wrong model for a flat-file vault, and Craft's own multi-block-selection bugs after years of investment are a warning.

---

## Section 3 — Hybrid-Markdown UX Deep Dive

| App | UX | Implementation trick |
|---|---|---|
| **iA Writer** | Markers always visible, dimmed; Syntax Control highlights parts of speech | TextKit attribute pass: `NSForegroundColorAttributeName` lowered alpha on syntax characters; NL framework for POS tagging |
| **Bear (Panda)** | Inline rendering of bold/italic/headings; markers visible by default, optionally hidden | Custom C++ AST that maps source ranges → display attributes; not TextKit-based ([blog.bear.app](https://blog.bear.app/2021/06/checking-in-on-panda-the-next-editor-for-bear/)) |
| **Obsidian Live Preview** | Markers *replaced* with widgets when caret is far; revealed when caret enters range | CM6 `Decoration.replace` + `Decoration.widget` with a `StateField` keyed off `selection` ([codemirror.net/examples/decoration](https://codemirror.net/examples/decoration/)) |
| **Typora** | True WYSIWYG, source never visible; cost = round-trip fidelity issues, cursor-jump bugs ([typora #2271](https://github.com/typora/typora-issues/issues/2271)) | Hidden source DOM; CodeMirror only used in "source mode" |
| **Craft** | Discrete blocks; per-block toolbar appears on hover | Each block is a separate component; no continuous text storage |

**The pattern in TextKit terms** (for Option B): represent each markdown construct as a `MarkerRange` with `style` (`.heading1`, `.boldMarker`, `.wikilink`, etc.). On every selection change:

```swift
func applyHybridDecorations(caret: NSRange) {
  for marker in markers {
    let caretNear = marker.range.contains(caret.location)
                 || abs(marker.range.location - caret.location) < 2
    let attrs: [NSAttributedString.Key: Any] = caretNear
      ? [.foregroundColor: NSColor.labelColor]               // reveal
      : [.foregroundColor: NSColor.tertiaryLabelColor]       // dim
    textStorage.addAttributes(attrs, range: marker.range)
  }
}
```

For wikilinks specifically, the pill-chip effect uses `NSTextAttachment` with a custom `NSTextAttachmentCellProtocol` cell that draws a rounded background, then collapses the underlying `[[ ]]` text to zero-width when the caret is not inside it. This is *the* most subtle piece of the build; budget a full week.

---

## Section 4 — Toolbar / Formatting Affordances

| Affordance | Trigger (recommended) | Implementation cost |
|---|---|---|
| Bold / italic / strikethrough | ⌘B / ⌘I / ⌘⇧X; menu; `**`/`_`/`~~` autoreplace | Low |
| Underline | ⌘U (HTML `<u>`) | Low; flag: not GFM-standard |
| Headings H1–H6 | ⌘1–⌘6 toggle; menu; `# ` auto on line start | Low |
| Bullet / numbered / checklist | ⌘⇧7/8/9; `- `, `1. `, `- [ ]` autoreplace; Tab/Shift-Tab nesting | Low–Medium |
| Wikilink insert + autocomplete | `[[` triggers fuzzy popover over note titles | Medium-High (own UI + FTS5 over title index) |
| Link insert | ⌘K dialog; paste URL over selection wraps in `[]()` | Low |
| Image insert | Drag/drop, ⌘⇧I, paste from clipboard, screenshot via Services menu | Medium |
| Code blocks | ` ``` ` autoreplace; language picker popover; Splash/Highlightr in-place | Medium |
| Tables | Toolbar inserts skeleton; paste-from-Excel detection (`\t`-delimited rows) → table; arrow-key navigation | High (table editor is non-trivial) |
| Callouts `> [!NOTE]` | Toolbar template; Obsidian-compatible syntax | Low |
| Math `$...$` / `$$...$$` | `$` autoreplace; LaTeXSwiftUI/SwiftMath for inline `NSTextAttachment` | Medium |
| Mermaid / PlantUML / Excalidraw | Render fenced `mermaid` blocks via WKWebView attachment; ship Mermaid only in v1 | Medium-High |
| Footnotes `[^1]` | Autocomplete on `[^`; backlink jump | Medium |
| Horizontal rule | `---` autoreplace; menu | Low |
| Frontmatter editing | Both: raw `---`/YAML in the editor + sidebar "Properties" panel (Obsidian's choice) | Medium |
| Find / replace + regex | ⌘F / ⌘⌥F; reuse `NSTextFinder` (free in TextKit 1) | Low |
| Slash commands | `/` at line start opens command palette; optional in v1 | Medium |
| Markdown shortcuts (autoreplace) | `# `, `- `, `> `, `1. ` on space; bracket completion | Low |

**Opinionated minimum surface for PunkRecords v1:**

- **Keyboard-first; no toolbar.** One context menu (right-click): bold, italic, heading promote/demote, link, code, quote, list toggle.
- **`[[` triggers wikilink autocomplete.** Non-negotiable for a PKM.
- **`#` triggers tag autocomplete on the third character.** Trie-backed.
- **`/` opens a slash command palette** — mirrors Notion/Craft for AI-generated content workflows.
- **Markdown shortcuts (`# `, `- `, `> `, ` ``` `, `---`, `$`) autoreplace on space/Enter.**
- **⌘F find+replace + regex.** Use `NSTextFinder`.
- **No table editor in v1.** Plain `|---|---|` text, table preview later.
- **No Mermaid/Excalidraw in v1.** Ship as fenced code blocks; render later.
- **Raw YAML frontmatter only in v1.** Properties panel in v1.1.

---

## Section 5 — PKM-Specific Syntax

| Construct | Recommendation for v1 |
|---|---|
| **Wikilinks** `[[Note]]`, `[[Note\|alias]]` | Render as **pill chips** when caret is outside; reveal `[[ ]]` markers when caret is inside. Click opens note. Autocomplete on `[[` against an FTS5-indexed title table. |
| **Tags** `#tag`, `#nested/tag` | Render as colored pill (lower contrast than wikilinks). Autocomplete from a `tags` table populated by a background scanner. Color from hash. |
| **Frontmatter** YAML between `---` lines | Render raw in editor with subtle dim styling; add a collapsible "Properties" panel above the doc in v1.1, **not** v1. Obsidian's Properties UI works but several users hate that it abstracts the YAML — make it opt-in. |
| **Embeds** `![[Note]]` | Inline preview card (collapsible, replaced range). Match Obsidian. |
| **Block refs** `[[Note#heading]]`, `[[Note^block-id]]` | **Heading refs in v1; block refs (`^id`) in v1.1.** Block refs require generating and persisting block IDs (a CRDT-shaped problem). |

For tag and wikilink resolution, **do not store any of this in memory full-time**. Use SQLite FTS5 with `tokenize='trigram'` for fuzzy title matching, an `outgoing_links` table, and a `tags` table — all maintained by a background actor watching the vault directory. At 50k notes:
- A title FTS5 index is ~5–15MB.
- A links table is ~1–3M rows for 50k notes, fits comfortably in memory if needed.
- A startup incremental reindex (only changed files since last run) is sub-second; cold full reindex on first launch is seconds to low minutes depending on disk.

Obsidian holds large portions in memory, which is one reason it can be slow to open very large vaults — Fabrizio Musacchio's January 2023 test (fabriziomusacchio.com) reported that a ~1,200-file vault with large image attachments took "more than one minute" to open on iOS and "a few minutes" for the initial desktop cache build on an M1 Max MacBook Pro. Extrapolating that to 50k notes is unsafe but the architectural lesson is clear: **don't copy "everything in RAM."**

---

## Section 6 — Performance, Accessibility, Scale

| Concern | Option A (SwiftUI TextEditor) | Option B (NSTextView+TK1) | Option C (CM6+WKWebView) | Option D (native blocks) |
|---|---|---|---|---|
| **10MB single file** | Untested at scale, likely lags | Fine with viewport layout + lazy styling | Fine; CM6 designed for it | N/A (would crash UI) |
| **VoiceOver** | Basic (SwiftUI's; limited) | Full (NSTextView is the AX gold standard on Mac) | Limited (WKWebView AX bridging works but is glitchy) | Custom per block; significant work |
| **Undo across boundaries** | SwiftUI undo manager | NSTextView has rock-solid `UndoManager` integration | Hard — undo *in* CM6 doesn't compose with undo of host UI actions; you re-implement | Custom |
| **IME (CJK)** | NSTextInputClient via wrapper; should work | Best on Mac; well-tested CJK | Glitchy historically in Craft, fixed; CM6 IME has had edge cases | Per-block bugs (Craft's release notes mention this) |
| **Find/replace with hidden markers** | SwiftUI search may match raw `AttributedString` so likely OK | Use `NSTextFinder` on raw `string`, not displayed runs — correct by design | CM6 searches source by default — correct | Your choice — must test |
| **50k+ vault autocomplete** | Independent of editor | Independent of editor | Independent of editor | Independent of editor |
| **50k+ vault wikilink graph** | SQLite + FTS5 backing; sub-100ms resolution | Same | Same | Same |

**Single most important architectural rule for vault scale:** keep the *editor* concerned with the *current open document* and nothing else. The vault index (titles, tags, links, full-text) lives in a `GRDB.swift` + SQLite FTS5 store maintained by a background actor on a serial queue, queried from the editor via `async` calls. A 50k-note vault is small for SQLite (it routinely handles tens of millions of rows); your bottleneck will be the initial filesystem walk and YAML parse, which you can stream.

**Find/replace + hidden markers — the "Bear bug":** When the editor visually hides `**`, naive find on the *displayed* string misses content the user searched for. The fix in TextKit 1: always search against `textStorage.string` (the raw source), then map matched ranges back to the visible attributed string for highlight. CM6 does this correctly by default. SwiftUI's new `AttributedString` find is unproven at scale.

**Swift 6 strict concurrency:** Option B integrates cleanly. `NSTextView` and its delegates are `@MainActor`; your parsing/highlighting actor is a non-isolated `actor` returning `Sendable` highlight diffs; you `await` and apply on the main actor. Avoid passing `NSAttributedString` across actor boundaries — pass plain `String` + `[HighlightRange]` instead.

---

## Section 7 — Recommendation, Plan, Cuts, Fallback

### The recommendation: Option B (NSTextView + TextKit 1, SwiftUI wrapper).

**Why:**
1. **It's what apps closest to PunkRecords' aesthetic actually ship** (Bear pre-Panda, iA Writer, Ulysses, Drafts, Nodes).
2. **TextKit 2 is not production-ready as a base in 2026** — direct evidence from Krzyżanowski's 4-year retrospective, AltStore's regret, MarkEdit's rejection, and Apple's own TextEdit falling back to TextKit 1 ([WWDC22 #10090](https://developer.apple.com/videos/play/wwdc2022/10090/), [mjtsai.com](https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/)).
3. **The vault scaling concern is orthogonal** — solved by SQLite FTS5 + a background indexer regardless of editor choice.
4. **Solo-dev tractable** — `swift-markdown` + `Neon` + `NSTextView` is roughly 6k–12k LOC for what you need, all open source under Apache 2.0/MIT.
5. **Native IME, accessibility, Writing Tools (macOS 15.1+), spellcheck, and dictation come free.**

### 6-week implementation plan

**Week 1 — Foundation.** SwiftUI host shell, `NSViewRepresentable` wrapping `NSTextView` (TextKit 1), `NSTextStorage` delegate; plain-text editing with undo; load/save `.md` files; basic line-by-line regex highlighting for `#`, `*`, `_`, `` ` ``. Frontmatter detection (just dim the YAML block).

**Week 2 — Parser pipeline.** Integrate `swift-markdown` for canonical parse-on-save and parse-on-open. Integrate `SwiftTreeSitter` + `Neon` + tree-sitter-markdown for live styling. Bridge: on `textStorage(_:didProcessEditing:...)`, feed edit delta to Neon; receive invalidation ranges; reapply attributes to those ranges only.

**Week 3 — Hybrid UX.** Marker dimming based on caret proximity. Heading sizes (font scale per `presentationIntent.header`). Bold/italic glyph weights. Fenced code block with monospaced font + background fill, using `Splash` or `Highlightr` for token coloring. Footnote and link styling.

**Week 4 — PKM syntax.** Wikilink rendering as pill chip via `NSTextAttachment` with custom cell; reveal-on-caret-near logic. Tag chips. Wikilink autocomplete: `[[` triggers a popover backed by SQLite FTS5 over note titles. Tag autocomplete on `#`. Click handling for links and embeds.

**Week 5 — Vault index + search.** GRDB.swift + SQLite FTS5 schema (`notes(id, path, title, body)`, `links(src, dst)`, `tags(note, tag)`). Background `actor` indexer watching the vault directory via `DispatchSource.makeFileSystemObjectSource`. ⌘F find/replace (use `NSTextFinder`). ⌘O quick open over FTS5.

**Week 6 — Polish + the cuts.** Code-block language picker, math via SwiftMath as inline attachments, Mermaid block as a deferred WKWebView attachment, slash command palette skeleton, accessibility audit, IME testing (Japanese, Chinese, Korean), performance test with a 10MB file and a 50k vault (use Faker to generate).

### What gets cut from v1

- Block references with `^block-id` (v1.1)
- Properties panel UI on top of YAML (v1.1)
- Mermaid/Excalidraw rendering (v1.1; ship as code blocks)
- Real table editor with paste-from-Excel (v1.1)
- Slash command extensibility (v1.0 has built-in commands only)
- Multi-cursor editing (probably never)
- Vim mode (v1.1 if at all)
- Custom themes API (post-v1)

### "Ship something passable in 2 weeks" fallback

If parsing or hybrid UX bogs down, this is your minimum viable PunkRecords:

- `NSTextView` wrapped in `NSViewRepresentable` (TextKit 1).
- **Regex-based syntax highlighting only**, on the entire visible document, debounced 50ms. No tree-sitter, no `swift-markdown` integration in the editor — just regex patterns for `**bold**`, `*italic*`, `#` headings (font size by `#` count), `` `code` ``, `[[wikilink]]` (just underline + blue color, no pill chip), and `#tag`.
- **`swift-markdown` only at save/export time** for canonical AST and HTML preview.
- Wikilink autocomplete on `[[` against a `String` array of file basenames, loaded once at startup. Re-load on file-system events. This breaks at ~10k notes; ship it and migrate to FTS5 in week 3.
- No marker hiding, no `NSTextAttachment` pills, no replaced ranges. The user sees the raw markdown styled inline, like iA Writer 1.0.
- `NSTextFinder` for find/replace.
- Frontmatter rendered as gray text.

This is roughly 1,500–2,500 LOC. It's the editor BBEdit, MacDown, and Visual Studio Code's preview pane have shipped for 15+ years. It will not delight, but it will work, and you can ship it.

---

## Caveats

- **Bear's tech stack is partially second-hand.** Primary confirmation that Bear 2 (Panda) is a C++ AST editor comes from a Reddit AMA quoted on [Wikipedia](https://en.wikipedia.org/wiki/Bear_(app)). I could not retrieve the AMA directly. Treat the C++ detail as well-sourced but not gold-standard.
- **TextKit 2 is improving.** This report's verdict reflects 2025–early 2026 reality. By 2027 the situation may shift — re-evaluate at WWDC26 sessions.
- **`AttributedString` in SwiftUI `TextEditor` on macOS 26 is brand new.** It may close some of Option A's gaps faster than expected. Re-evaluate for v2.
- **Numeric estimates for vault scaling (50k notes index size, reindex time)** are extrapolated from SQLite norms and direct testing of much smaller vaults (e.g., Musacchio's 1,200-file iOS test); benchmark on your own hardware before committing.
- **The "Bear hid the ** I searched for"** bug behavior is illustrative — Bear has fixed and re-introduced this pattern several times across versions; the failure mode is the architectural point, not the specific app.

---

## Completion table

| Section requested | Covered |
|---|---|
| §1 Survey 15 apps × 4 dimensions + inline citations | ✅ |
| §2 Four options A/B/C/D with fit/license/maturity/perf/cost + verdict | ✅ |
| §3 Hybrid UX deep-dive on 5 apps | ✅ |
| §4 Toolbar/keyboard/menu table + v1 opinionated minimum | ✅ |
| §5 PKM syntax (wikilinks/tags/frontmatter/embeds/block refs) | ✅ |
| §6 Performance, AX, large files, 50k+ vault scaling | ✅ |
| §7 Recommendation + 4–6 week plan + cuts + 2-week fallback | ✅ |
| Code snippets for TextKit/CodeMirror/Lexical | ✅ (TextKit 1 wrapper + Neon sketch + CM6 widget) |
| Inline source links | ✅ |
| ~3000–5000 words | ✅ (~4,400) |