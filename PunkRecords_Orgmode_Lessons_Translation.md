Org-mode → macOS: a translation guide
The translation principle is this: every Org feature that survives needs to land on a control, gesture, or idiom that a Mac user has used in another app since 2005. If the closest analog is "an Emacs keybinding," reject it. If it lives in Finder, Mail, Reminders, or Spotlight, keep it.
Org mode's genius is that it built a database, a calendar, a task manager, and an outliner into one plain-text format. Apple's genius is that it built those same primitives as separate apps with shared conventions: Smart Folders, the Inspector, the Share Sheet, DataDetectors, NSOutlineView, the Spotlight-style picker. The lessons translate when we route Org's concepts through Apple's existing vocabulary instead of inventing new syntax.

What survives translation
1. Saved structured queries → Smart Notes (the Smart Folder pattern)
Org's agenda view is conceptually identical to Smart Folders in Finder, Smart Mailboxes in Mail, Smart Albums in Photos, and the built-in "Today / Scheduled / Flagged" lists in Reminders. This is the single strongest projection in the whole exercise — Apple has shipped this pattern for 20 years, and users already understand it.
The macOS-native form:

A "Smart Notes" section in the sidebar, below the file tree. Ships with built-in queries: Inbox, Today, This Week, Untagged, Recently Captured, Web Summaries.
"New Smart Note…" opens a sheet using NSPredicateEditor — the same rule-builder UI that Finder, Mail, and Photos all use. Predicates over: tag, status, frontmatter key, date created/modified, scheduled date, full-text match. (NSPredicateEditor docs)
The saved query is itself a markdown file in Smart Notes/Today.md with frontmatter holding the predicate. Plain-text-on-disk, Mac-native UI on top.

Why this kills it: every PKM in the report (Section 1) ships saved searches as a flat keyword string or a community plugin. None of them surface the macOS-native rule-builder. You'd ship the most usable structured query UI in the entire category in about three days of NSPredicateEditor wiring.
2. Per-heading metadata → the Inspector panel (⌘I)
Org's :PROPERTIES: drawer attaches arbitrary key-value data to any heading. The Mac-native pattern for "metadata about the selected thing" has been Get Info / Inspector (⌘I) since System 7. Finder, Pages, Keynote, Xcode, every Apple app does this.
The macOS-native form:

Cursor is on a heading → ⌘I opens an inspector pane on the right (or a popover if the user prefers minimal chrome). Fields: tags, status, scheduled, due, custom properties (key-value rows).
Saving the inspector writes a > [!props] callout block immediately under the heading, or appends to frontmatter if it's the document root. The on-disk format is markdown; the in-app form is a familiar inspector.
The inspector mirrors Reminders.app's task detail panel almost exactly: title, notes, due date, priority, tags, list. Users already know this layout.

Reject the bare Org syntax. Nobody on a Mac is going to type :SCHEDULED: <2026-05-17 Sun +1w>. They'll type "next Monday" in a date field and let DataDetectors do the work.
3. Sparse-tree search → filterable outline (the Xcode Project Navigator pattern)
When you type in Xcode's Project Navigator filter field, the file tree collapses to show only matching files and their containing groups. This is exactly Org's sparse tree, and it's a native macOS interaction Mac users already know from Xcode, Finder's column view drill-down, and Mail's filtered thread view.
The macOS-native form:

The sidebar uses NSOutlineView (or SwiftUI's OutlineGroup). When the search field has focus, the outline filters: matching headings stay visible, ancestors stay visible to preserve context, everything else collapses.
Hit count badges on parent folders (like Mail's unread counts). Click a result → main editor opens that file scrolled and highlighted at the match.
Plain ⌘F inside an open document does the standard find bar. ⌘⇧F is the vault-wide sparse-tree search. This matches Xcode's distinction between document find and project find.

The trick to get right: the sparse-tree result should preserve hierarchical context (file → H1 → H2 → matched H3), not just a flat list of hits. That context is the whole point.
4. Capture templates → menu-bar picker (the Raycast / QuickSilver pattern)
Org's org-capture is a templated picker. On macOS this is a menu bar app with a global hotkey that opens a picker. Raycast, Alfred, Drafts, and Things' Quick Entry all use this exact pattern; Mac users have been using QuickSilver-style launchers since 2003.
The macOS-native form:

NSStatusItem in the menu bar. Global hotkey (user-configurable, default ⌃Space or ⌘⇧Space). Opens a borderless floating panel.
First keystrokes filter a template list: Note, Journal entry, Meeting note, Web summary (paste a URL), Task, Idea. Each template has a destination file and a structured form.
Templates are themselves markdown files in .punkrecords/templates/ with a frontmatter header declaring fields. Users can author new templates in the editor itself. No DSL.
Bonus integrations Mac users expect:

Share Sheet extension — "Send to PunkRecords" appears in Safari, Mail, Messages, and any app that publishes shareable content.
Services menu — select text anywhere → Services → "New PunkRecords note from selection."
Shortcuts.app actions — expose capture as a Shortcut so users can build their own automation. (App Intents framework)



This trio (status item + Share Sheet + Shortcuts) is the macOS-native capture trinity. Together they make the app available from every place a Mac user might want to capture.
5. Refile → Spotlight-style move picker
Org's org-refile (move a heading anywhere) is the same pattern as Things' "Move to project…", Apple Notes' "Move Note…", and OmniFocus's reorganize-by-keyboard. The native idiom is a fuzzy-search picker sheet, not drag-and-drop.
The macOS-native form:

⌘⇧M with cursor on a heading → modal sheet, single text field, fuzzy-matched results showing File ▸ Heading ▸ Sub-heading paths. Enter to move.
Looks and feels like Xcode's "Open Quickly" (⌘⇧O). Built with a single NSTextField and a filtered list view. Two days to ship.
Keep drag-and-drop as a secondary affordance in the sidebar for whole-file moves; refile-by-picker is for sub-heading granularity where dragging is awkward.

6. Dates everywhere → DataDetectors + Reminders-style smart lists
Org's date syntax is an in-line DSL because Emacs doesn't have rich text. macOS has had DataDetectors since Mac OS X 10.5 — the framework that recognizes dates, addresses, phone numbers, and flight numbers in any text and offers contextual actions.
The macOS-native form:

User writes "lunch with Erin Tuesday" in a note. DataDetectors recognizes "Tuesday," underlines it on hover, and offers "Schedule," "Add to Calendar," "Surface in Today smart note."
A scheduled: or due: property in the heading inspector accepts natural language ("next Friday at 3", "+2w") and resolves it through NSDataDetector or Foundation.DateFormatter with relative parsing.
The Today smart note (from item 1) is the agenda. No new view to build; it's just a Smart Note with predicate scheduled <= today AND status != done.

This is where Mac-native really wins: Apple has already solved the "find dates in arbitrary text" problem with a system API that's been hardened for 17 years.
7. Folding → just ship it, the way Bear and Craft do
NSOutlineView and SwiftUI's OutlineGroup give you heading-folding for free. Click the disclosure chevron next to a heading; ⌘. toggles the heading under the cursor; ⌘⌥. folds all. This is no longer exotic — every modern Mac markdown editor (Bear, Craft, iA Writer, Pages, even Apple Notes for collapsible sections) does this. Just don't skip it.
8. The format is a contract → Quick Look generator
Apple's Quick Look (spacebar preview in Finder) is the most underused integration point in Mac apps. If PunkRecords ships a Quick Look generator for its frontmatter+callouts conventions, users get rich previews of vault notes from Finder, Mail attachments, AirDrop, and Spotlight results — without opening the app. (QuickLookThumbnailing) This is the macOS-native answer to "the format is the API": let other apps see your data.

What does NOT survive translation
Each of these is a beloved Org feature with no plausible Mac-native projection. Including them would be cargo-culting Emacs into a Mac app.

The :LOGBOOK: drawer / state-transition history. Mac users expect undo for recent changes and git/Time Machine for history. Don't bake an audit log into the document.
Custom TODO state sets per file. Reminders has one binary state. Things has three. Five user-configurable states with file-local definitions is Emacs-tier configurability with negative returns. Ship todo / doing / done, hard-coded, and stop.
org-babel executable code blocks. Jupyter and Mathematica exist for this. The PKM should not also be a notebook runtime. The agent loop (with its tools) is the executable surface.
The Org hyperlink format [[file:foo.org::*Heading][label]]. Markdown's [text](url) plus [[wikilinks]] already cover internal and external links. Three link formats is two too many.
Clocking (clock in / clock out on tasks). Time tracking is a separate app category (Toggl, Timing.app on Mac). Don't compete.
Column view of properties as a spreadsheet. Dataview-in-Obsidian style tabular query results. Defer; covered already by Smart Notes rendered as a list with sortable columns if needed.
Sparse-tree visibility cycling (multiple zoom levels). Two states (folded/expanded) is enough. Three+ is Emacs muscle memory.


The two-week sprint
Five working days of build, five of polish. Order is dependency-aware.
Days 1–2: Inspector panel (⌘I). Side pane with editable fields for the heading at the cursor: title, tags, status, scheduled, due, custom kv. Writes a > [!props] callout block. This unblocks everything else because it's the schema surface.
Days 3–4: Smart Notes with NSPredicateEditor. Sidebar section, sheet for creating/editing, predicate over the frontmatter+properties+FTS index you already have. Ships with Today, This Week, Inbox, Untagged, Web Summaries. This is the demo screenshot.
Day 5: Sparse-tree search in the sidebar. SwiftUI OutlineGroup driven by a filtered data source. ⌘⇧F focuses the field; type to filter; ancestors stay visible.
Day 6: Menu bar status item + global hotkey + template picker. Three templates to start: Note, Journal entry, Web summary. Templates are markdown files with frontmatter.
Day 7: Share Sheet extension. "Send to PunkRecords" from Safari. Drops the URL into the Web Summary template, runs the existing summarize_url tool, opens the resulting note.
Days 8–9: Refile picker (⌘⇧M) + folding. Both are small. Refile is a fuzzy-match sheet against (file, heading-path) tuples. Folding is one line in SwiftUI if you've already structured headings as an outline.
Day 10: DataDetectors + Today integration. Wire NSDataDetector into the note renderer to underline detected dates; cmd-click opens a popover with "Schedule" / "Add to Calendar." The "Today" Smart Note from day 4 picks them up via predicate. Quick Look generator if you have time left.
What you'd have at the end of two weeks: a Mac-native PKM with structured saved searches, inspector-driven metadata, sparse-tree search, a status-bar capture surface, Share Sheet integration, fuzzy refile, folding, and DataDetector-powered dates — every one of which Mac users already know how to use because they learned it in Finder, Mail, Reminders, or Xcode. None of which requires the user to learn Org syntax, Emacs bindings, or a configuration DSL.
That's the translation: Org's database becomes a Smart Folder; Org's properties become a Get Info pane; Org's agenda becomes the Today smart list; Org's capture becomes the menu bar + Share Sheet + Shortcuts trinity. Everything else gets cut.
