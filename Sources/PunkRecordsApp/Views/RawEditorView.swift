import SwiftUI
import AppKit
import PunkRecordsCore
import PunkRecordsInfra

struct RawEditorView: View {
    let documentPath: RelativePath
    @Environment(AppState.self) private var appState
    @State private var viewModel: DocumentEditorViewModel?
    @State private var isPreviewing = false
    @AppStorage("editor.emacsKeybindings") private var emacsKeybindings = false
    @AppStorage("editor.themeID") private var themeID = EditorThemeCatalog.defaultID
    @AppStorage("editor.livePreview") private var livePreview = true

    var body: some View {
        // Resolve the user's chosen editor theme (persisted in Settings). The
        // `.id(themeID)` below rebuilds the editor through the proven makeNSView
        // path on change, so switching themes applies live without reopening.
        let theme = EditorThemeCatalog.theme(forID: themeID)
        return Group {
            if let viewModel {
                if isPreviewing {
                    MarkdownPreviewView(
                        content: viewModel.document.content,
                        theme: theme,
                        onOpenNote: { target in openNoteByTitle(target) },
                        onOpenTag: { tag in appState.sidebarFilterQuery = "tag:\(tag)" }
                    )
                } else {
                    EditorTextViewRepresentable(
                        viewModel: viewModel,
                        onAskAI: { selectedText in
                            appState.askAIText = selectedText
                            appState.isChatPanelVisible = true
                        },
                        onSelectionChanged: { selectedText in
                            appState.selectedText = selectedText
                        },
                        onCaretChanged: { caret in
                            appState.editorCaretLocation = caret
                        },
                        onTextChanged: { text in
                            appState.editorText = text
                        },
                        isWikilinkResolved: { target in
                            appState.documents.contains {
                                $0.title.caseInsensitiveCompare(target) == .orderedSame
                            }
                        },
                        onWikilinkClick: { action in
                            handleWikilinkClick(action)
                        },
                        wikilinkCompletions: { query in
                            QuickOpenMatcher.match(
                                documents: appState.documents,
                                query: query,
                                limit: 8
                            ).map(\.document.title)
                        },
                        tagCompletions: { query in
                            TagAutocomplete.suggestions(
                                matching: query,
                                in: appState.distinctTags,
                                limit: 8
                            )
                        },
                        onTagClick: { tag in
                            appState.sidebarFilterQuery = "tag:\(tag)"
                        },
                        emacsEnabled: emacsKeybindings,
                        theme: theme,
                        livePreviewEnabled: livePreview
                    )
                    .id(themeID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle(viewModel?.document.title ?? "")
        .navigationSubtitle(viewModel?.isDirty == true ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(
                    isPreviewing ? "Edit" : "Preview",
                    systemImage: isPreviewing ? "pencil" : "eye"
                ) {
                    isPreviewing.toggle()
                }
                .help(isPreviewing ? "Switch back to the markdown source" : "Render the document with GitHub-flavored markdown")
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Compile to Wiki", systemImage: "doc.text.magnifyingglass") {
                    Task { await compileCurrentDocument() }
                }
                .help("Compile this document into a structured wiki article using AI")
                .disabled(appState.noteCompiler == nil)

                Button("Backlinks", systemImage: "link") {
                    appState.isBacklinksPanelVisible.toggle()
                }
                .help("Toggle Backlinks Panel")

                Button("AI Chat", systemImage: "bubble.left.and.text.bubble.right") {
                    appState.isChatPanelVisible.toggle()
                }
                .help("Toggle AI Chat Panel")
            }
        }
        .task(id: documentPath) {
            await loadDocument()
        }
        .onChange(of: appState.editorReloadToken) {
            // A refile rewrote files on disk; reload so the open note reflects it.
            Task { await loadDocument() }
        }
    }

    /// Open a note by title, or prompt to create it when none exists. Shared by
    /// the editor's pill clicks and the preview's `[[wikilink]]` links.
    private func openNoteByTitle(_ title: String) {
        let resolved = appState.documents.contains {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
        }
        handleWikilinkClick(resolved ? .open(target: title) : .create(title: title))
    }

    /// Open the clicked wikilink, or prompt to create it when it has no note.
    private func handleWikilinkClick(_ action: WikilinkDecorator.ClickAction) {
        switch action {
        case .open(let target):
            if let doc = appState.documents.first(where: {
                $0.title.caseInsensitiveCompare(target) == .orderedSame
            }) {
                appState.selectedDocumentPath = doc.path
            }
        case .create(let title):
            let alert = NSAlert()
            alert.messageText = "Create “\(title)”?"
            alert.informativeText = "No note titled “\(title)” exists yet. Create it now?"
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                appState.createNote(titled: title)
            }
        }
    }

    private func compileCurrentDocument() async {
        guard let vm = viewModel,
              let compiler = appState.noteCompiler else { return }
        do {
            let doc = try await compiler.compileFromSource(
                sourceContent: vm.document.content,
                sourceTitle: vm.document.title,
                folderPath: ""
            )
            appState.selectedDocumentPath = doc.path
        } catch {
            appState.errorMessage = "Failed to compile note: \(error.localizedDescription)"
        }
    }

    private func loadDocument() async {
        guard let repo = appState.repository else { return }
        do {
            if let doc = try await repo.document(atPath: documentPath) {
                viewModel = DocumentEditorViewModel(
                    document: doc,
                    repository: repo,
                    searchIndex: appState.searchIndex,
                    recoveryStore: appState.recoveryStore
                )
                // Keep AppState's live-editor mirror in sync so refile reads the
                // freshly-loaded content (not a stale pre-reload value).
                appState.editorText = doc.content
                appState.editorCaretLocation = 0
            }
        } catch {
            appState.errorMessage = "Failed to load document: \(error.localizedDescription)"
        }
    }
}

#Preview("Raw Editor — With Document") {
    EditorTextViewRepresentable(
        viewModel: DocumentEditorViewModel(
            document: PreviewData.sampleDocument,
            repository: FileSystemDocumentRepository(
                vaultRoot: PreviewData.previewVaultURL,
                ignoredPaths: []
            ),
            searchIndex: nil
        )
    )
    .frame(width: 700, height: 500)
}

/// NSViewRepresentable wrapper for NSTextView with tree-sitter syntax
/// highlighting, hybrid-UX decoration, and wikilink/tag pill chips.
struct EditorTextViewRepresentable: NSViewRepresentable {
    let viewModel: DocumentEditorViewModel
    var onAskAI: ((String) -> Void)?
    var onSelectionChanged: ((String?) -> Void)?
    /// Reports the caret's UTF-16 location on every selection change.
    var onCaretChanged: ((Int) -> Void)?
    /// Reports the full editor text on every change.
    var onTextChanged: ((String) -> Void)?
    var isWikilinkResolved: ((String) -> Bool)?
    var onWikilinkClick: ((WikilinkDecorator.ClickAction) -> Void)?
    /// Returns candidate note titles for a `[[` autocomplete query, best-first.
    var wikilinkCompletions: ((String) -> [String])?
    /// Returns candidate tag names for a `#` autocomplete query, best-first.
    var tagCompletions: ((String) -> [String])?
    /// Invoked with a tag name when a `#tag` pill is clicked (click-to-filter).
    var onTagClick: ((String) -> Void)?
    /// Whether Emacs keybindings are active in the editor.
    var emacsEnabled: Bool = false
    var theme: EditorTheme = .dracula
    /// Whether Live Preview marker folding is active (mirrors the
    /// `editor.livePreview` setting). When false the editor stays dim-only.
    var livePreviewEnabled: Bool = true

    init(
        viewModel: DocumentEditorViewModel,
        onAskAI: ((String) -> Void)? = nil,
        onSelectionChanged: ((String?) -> Void)? = nil,
        onCaretChanged: ((Int) -> Void)? = nil,
        onTextChanged: ((String) -> Void)? = nil,
        isWikilinkResolved: ((String) -> Bool)? = nil,
        onWikilinkClick: ((WikilinkDecorator.ClickAction) -> Void)? = nil,
        wikilinkCompletions: ((String) -> [String])? = nil,
        tagCompletions: ((String) -> [String])? = nil,
        onTagClick: ((String) -> Void)? = nil,
        emacsEnabled: Bool = false,
        theme: EditorTheme = .dracula,
        livePreviewEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        self.onAskAI = onAskAI
        self.onSelectionChanged = onSelectionChanged
        self.onCaretChanged = onCaretChanged
        self.onTextChanged = onTextChanged
        self.isWikilinkResolved = isWikilinkResolved
        self.onWikilinkClick = onWikilinkClick
        self.wikilinkCompletions = wikilinkCompletions
        self.tagCompletions = tagCompletions
        self.onTagClick = onTagClick
        self.emacsEnabled = emacsEnabled
        self.theme = theme
        self.livePreviewEnabled = livePreviewEnabled
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // TextKit 1 stack + themed text view (view/storage/layout construction).
        let (scrollView, textView) = EditorTextKitFactory.makeEditor(
            theme: theme,
            content: viewModel.document.content
        )
        textView.delegate = coordinator

        // Syntax highlighting + hybrid/wikilink decoration (theme-derived).
        do {
            coordinator.highlighter = try TreeSitterMarkdownHighlighter(
                textView: textView,
                theme: theme.highlighterTheme
            )
        } catch {
            assertionFailure("Failed to initialize TreeSitterMarkdownHighlighter: \(error)")
        }
        coordinator.decorator = HybridUXDecorator(style: theme.decoratorStyle)
        coordinator.livePreviewDecorator = LivePreviewDecorator(
            style: .init(linkColor: theme.highlighterTheme.linkColor)
        )
        coordinator.livePreviewEnabled = livePreviewEnabled
        if let isResolved = isWikilinkResolved {
            coordinator.wikilinkDecorator = WikilinkDecorator(
                style: theme.wikilinkStyle,
                isResolved: isResolved
            )
        }
        textView.resolveWikilinkClick = { [weak coordinator] index in
            guard let coordinator else { return nil }
            return coordinator.wikilinkDecorator?.clickAction(at: index, in: textView.string)
        }
        textView.onWikilinkClick = onWikilinkClick
        textView.resolveTagClick = { [weak coordinator] index in
            guard let coordinator else { return nil }
            return coordinator.wikilinkDecorator?.tagTarget(at: index, in: textView.string)
        }
        textView.onTagClick = onTagClick
        // Markdown links render as just their styled label under Live Preview,
        // so a click on the label opens the URL (like the preview pane would).
        // In source mode (Live Preview off) clicks place the caret as usual.
        textView.resolveLinkClick = { [weak coordinator, weak textView] index in
            guard let coordinator, let textView, coordinator.livePreviewEnabled else { return nil }
            guard let target = MarkerFolding.linkTarget(at: index, in: textView.string) else { return nil }
            return URL(string: target)
        }
        textView.onLinkClick = { url in
            NSWorkspace.shared.open(url)
        }

        // Inline completion popover, shared by `[[` wikilinks and `#` tags.
        coordinator.completion.wikilinkCompletions = wikilinkCompletions
        coordinator.completion.tagCompletions = tagCompletions
        coordinator.completion.afterAccept = { [weak coordinator] textView in
            coordinator?.viewModel.updateContent(textView.string)
            coordinator?.runDecorations(on: textView)
        }
        if wikilinkCompletions != nil || tagCompletions != nil {
            let controller = WikilinkCompletionController()
            coordinator.completion.controller = controller
            controller.onAccept = { [weak coordinator] title in
                coordinator?.completion.accept(title, in: textView)
            }
            textView.completionController = controller
        }

        // Slash-command menu re-decorates after inserting a snippet.
        coordinator.slash.afterInsert = { [weak coordinator] textView in
            coordinator?.runDecorations(on: textView)
        }

        // Emacs keybinding dispatch.
        coordinator.emacsEnabled = emacsEnabled
        textView.isEmacsEnabled = { [weak coordinator] in
            coordinator?.emacsEnabled ?? false
        }
        textView.handleEmacsChord = { [weak coordinator] chord in
            coordinator?.handleEmacsChord(chord, in: textView) ?? false
        }

        coordinator.runDecorations(on: textView)

        // Re-decorate the newly visible region when the user scrolls — decoration
        // is limited to the visible range for performance, so scrolled-in content
        // needs a fresh pass.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        coordinator.observeScroll(of: clipView, textView: textView)

        // Make the NSTextView reachable from XCUITest. The wrapping
        // SwiftUI .accessibilityIdentifier modifier lands on a parent
        // view; we need the id on the TextView element itself so
        // clicks and right-clicks target the text content.
        textView.setAccessibilityIdentifier("editorTextView")

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.emacsEnabled = emacsEnabled
        if context.coordinator.livePreviewEnabled != livePreviewEnabled {
            context.coordinator.livePreviewEnabled = livePreviewEnabled
            // Re-run so the toggle applies immediately (fold or unfold all).
            context.coordinator.runDecorations(on: textView)
        }
        if !viewModel.isDirty && textView.string != viewModel.document.content {
            textView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: viewModel.document.content,
                    attributes: EditorTextKitFactory.baseAttributes(for: theme)
                )
            )
            context.coordinator.highlighter?.invalidateAll()
            context.coordinator.runDecorations(on: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(viewModel: viewModel, onAskAI: onAskAI)
        coordinator.onSelectionChanged = onSelectionChanged
        coordinator.onCaretChanged = onCaretChanged
        coordinator.onTextChanged = onTextChanged
        return coordinator
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let viewModel: DocumentEditorViewModel
        let onAskAI: ((String) -> Void)?
        var onSelectionChanged: ((String?) -> Void)?
        var onCaretChanged: ((Int) -> Void)?
        var onTextChanged: ((String) -> Void)?
        var highlighter: TreeSitterMarkdownHighlighter?
        var decorator: HybridUXDecorator?
        var wikilinkDecorator: WikilinkDecorator?
        /// Folds markdown markers (`**`, `` ` ``, `# `, `[[]]`, links…) to zero
        /// width when the caret is outside their element and styles link labels.
        /// Attribute + glyph only — never mutates text.
        var livePreviewDecorator: LivePreviewDecorator?
        /// Whether Live Preview folding is on; mirrored from the @AppStorage
        /// setting on every SwiftUI update (like `emacsEnabled`).
        var livePreviewEnabled = true
        /// Inline `[[`/`#` completion popover session (owns its own state).
        let completion = EditorCompletionCoordinator()
        /// `/` slash-command pop-up menu lifecycle.
        let slash = SlashCommandMenuController()
        /// Whether Emacs keybindings are active; mirrored from the @AppStorage
        /// setting on every SwiftUI update.
        var emacsEnabled = false

        // Emacs mark / kill-ring / yank state. Internal (not private) so the
        // dispatch logic in EditorCoordinator+Emacs.swift can reach it.
        var emacsMark: Int?
        var killRing = EmacsKillRing()
        var lastYankRange: NSRange?
        /// True while an Emacs command is mutating the text, so `textDidChange`
        /// doesn't clear mark/yank state mid-operation (only user edits should).
        var isPerformingEmacsEdit = false
        /// True after a `C-x` prefix, awaiting the second key of the sequence.
        var awaitingCtrlX = false

        init(viewModel: DocumentEditorViewModel, onAskAI: ((String) -> Void)? = nil) {
            self.viewModel = viewModel
            self.onAskAI = onAskAI
        }

        private var scrollObserver: NSObjectProtocol?

        /// Run the hybrid-UX and wikilink decoration passes in order.
        /// Wikilink pills go last so they win on any overlapping range.
        ///
        /// Skipped while an IME composition is in progress (marked text):
        /// rewriting attributes mid-composition can disrupt Japanese/Chinese/
        /// Korean input. Decoration resumes once the composition commits.
        func runDecorations(on textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            decorator?.decorate(textView: textView)
            wikilinkDecorator?.decorate(textView: textView)
            // Folding runs last: it reads attributes the color passes set and it
            // is the only pass that changes layout, so it owns the scoped
            // glyph/layout invalidation. Disabling it (Live Preview off) makes
            // the next pass unfold everything, restoring dim-only source mode.
            livePreviewDecorator?.isEnabled = livePreviewEnabled
            livePreviewDecorator?.decorate(textView: textView)
        }

        /// Re-run decorations on scroll so content scrolled into view is styled.
        /// The block holds `self` weakly, so it no-ops once the coordinator is
        /// gone; the observer is released when the clip view is deallocated.
        func observeScroll(of clipView: NSClipView, textView: NSTextView) {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated {
                    self.runDecorations(on: textView)
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let text = (textView.string as NSString).substring(with: selectedRange)
                onSelectionChanged?(text)
            } else {
                onSelectionChanged?(nil)
            }
            onCaretChanged?(textView.selectedRange().location)
            runDecorations(on: textView)
            completion.update(in: textView)
        }

        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let askItem = NSMenuItem(title: "Ask AI About Selection", action: #selector(askAIAction(_:)), keyEquivalent: "")
                askItem.target = self
                askItem.representedObject = textView
                menu.insertItem(askItem, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }

        @objc private func askAIAction(_ sender: NSMenuItem) {
            guard let textView = sender.representedObject as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0 else { return }
            let selectedText = (textView.string as NSString).substring(with: selectedRange)
            onAskAI?(selectedText)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // A user edit deactivates the mark and ends any yank-pop sequence;
            // Emacs-driven edits manage that state themselves.
            if !isPerformingEmacsEdit {
                emacsMark = nil
                lastYankRange = nil
            }
            // The view model owns autosave timing + crash-recovery sidecars:
            // updateContent(_:) marks dirty and (re)schedules the debounced +
            // periodic autosave. See DocumentEditorViewModel / AutosaveScheduler.
            viewModel.updateContent(textView.string)
            onTextChanged?(textView.string)
            runDecorations(on: textView)
            slash.maybeShowMenu(in: textView)
            completion.update(in: textView)
        }
    }
}
