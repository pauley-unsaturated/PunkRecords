import SwiftUI
import AppKit
import PunkRecordsCore
import PunkRecordsInfra

struct RawEditorView: View {
    let documentPath: RelativePath
    @Environment(AppState.self) private var appState
    @State private var viewModel: DocumentEditorViewModel?
    @State private var isPreviewing = false

    var body: some View {
        Group {
            if let viewModel {
                if isPreviewing {
                    MarkdownPreviewView(content: viewModel.document.content)
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
                        isWikilinkResolved: { target in
                            appState.documents.contains {
                                $0.title.caseInsensitiveCompare(target) == .orderedSame
                            }
                        },
                        onOpenWikilink: { target in
                            if let doc = appState.documents.first(where: {
                                $0.title.caseInsensitiveCompare(target) == .orderedSame
                            }) {
                                appState.selectedDocumentPath = doc.path
                            }
                        }
                    )
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
                    searchIndex: appState.searchIndex
                )
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

/// NSTextView subclass that opens a wikilink when its pill is clicked,
/// instead of placing the caret. Falls through to normal click behavior
/// everywhere else.
final class PillTextView: NSTextView {
    /// Maps a character index to a wikilink target, or nil if the index
    /// isn't inside a rendered pill. Set by the Coordinator.
    var resolveWikilinkTarget: ((Int) -> String?)?
    /// Invoked with the target when a pill is clicked.
    var onOpenWikilink: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let target = resolveWikilinkTarget?(index), !target.isEmpty {
            onOpenWikilink?(target)
            return
        }
        super.mouseDown(with: event)
    }
}

/// NSViewRepresentable wrapper for NSTextView with tree-sitter syntax
/// highlighting, hybrid-UX decoration, and wikilink/tag pill chips.
struct EditorTextViewRepresentable: NSViewRepresentable {
    let viewModel: DocumentEditorViewModel
    var onAskAI: ((String) -> Void)?
    var onSelectionChanged: ((String?) -> Void)?
    var isWikilinkResolved: ((String) -> Bool)?
    var onOpenWikilink: ((String) -> Void)?
    var theme: EditorTheme = .dracula

    init(
        viewModel: DocumentEditorViewModel,
        onAskAI: ((String) -> Void)? = nil,
        onSelectionChanged: ((String?) -> Void)? = nil,
        isWikilinkResolved: ((String) -> Bool)? = nil,
        onOpenWikilink: ((String) -> Void)? = nil,
        theme: EditorTheme = .dracula
    ) {
        self.viewModel = viewModel
        self.onAskAI = onAskAI
        self.onSelectionChanged = onSelectionChanged
        self.isWikilinkResolved = isWikilinkResolved
        self.onOpenWikilink = onOpenWikilink
        self.theme = theme
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont, .foregroundColor: theme.foreground]
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Build an explicit TextKit 1 stack with the pill-drawing layout
        // manager. Accessing a custom NSLayoutManager keeps us on TK1, which
        // the editor epic deliberately chose over TK2.
        let textStorage = NSTextStorage()
        let layoutManager = WikilinkPillLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = PillTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.insertionPoint
        textView.font = theme.bodyFont
        textView.textColor = theme.foreground
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.typingAttributes = baseAttributes
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: viewModel.document.content, attributes: baseAttributes)
        )
        textView.delegate = context.coordinator

        do {
            context.coordinator.highlighter = try TreeSitterMarkdownHighlighter(
                textView: textView,
                theme: theme.highlighterTheme
            )
        } catch {
            assertionFailure("Failed to initialize TreeSitterMarkdownHighlighter: \(error)")
        }
        context.coordinator.decorator = HybridUXDecorator(style: theme.decoratorStyle)
        if let isResolved = isWikilinkResolved {
            context.coordinator.wikilinkDecorator = WikilinkDecorator(
                style: theme.wikilinkStyle,
                isResolved: isResolved
            )
        }
        textView.resolveWikilinkTarget = { [weak coordinator = context.coordinator] index in
            guard let coordinator else { return nil }
            return coordinator.wikilinkDecorator?.wikilinkTarget(at: index, in: textView.string)
        }
        textView.onOpenWikilink = onOpenWikilink
        context.coordinator.runDecorations(on: textView)

        // Re-decorate the newly visible region when the user scrolls — decoration
        // is limited to the visible range for performance, so scrolled-in content
        // needs a fresh pass.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: clipView, textView: textView)

        // Make the NSTextView reachable from XCUITest. The wrapping
        // SwiftUI .accessibilityIdentifier modifier lands on a parent
        // view; we need the id on the TextView element itself so
        // clicks and right-clicks target the text content.
        textView.setAccessibilityIdentifier("editorTextView")

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !viewModel.isDirty && textView.string != viewModel.document.content {
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: viewModel.document.content, attributes: baseAttributes)
            )
            context.coordinator.highlighter?.invalidateAll()
            context.coordinator.runDecorations(on: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(viewModel: viewModel, onAskAI: onAskAI)
        coordinator.onSelectionChanged = onSelectionChanged
        return coordinator
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let viewModel: DocumentEditorViewModel
        let onAskAI: ((String) -> Void)?
        var onSelectionChanged: ((String?) -> Void)?
        var highlighter: TreeSitterMarkdownHighlighter?
        var decorator: HybridUXDecorator?
        var wikilinkDecorator: WikilinkDecorator?
        private var debounceTask: Task<Void, Never>?

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
            runDecorations(on: textView)
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
            viewModel.updateContent(textView.string)
            runDecorations(on: textView)
            maybeShowSlashMenu(in: textView)

            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                try? await viewModel.save()
            }
        }

        // MARK: - Slash command palette

        /// Pops up the slash-command menu when the user has just typed a bare
        /// `/` at the start of a line or after whitespace.
        private func maybeShowSlashMenu(in textView: NSTextView) {
            let caret = textView.selectedRange().location
            guard let session = SlashCommandLibrary.activeSession(
                in: textView.string,
                caretLocation: caret
            ), session.query.isEmpty else { return }

            let menu = NSMenu()
            for command in SlashCommandLibrary.all {
                let item = NSMenuItem(
                    title: command.title,
                    action: #selector(slashCommandSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.image = NSImage(systemSymbolName: command.systemImage, accessibilityDescription: command.title)
                item.toolTip = command.subtitle
                item.representedObject = SlashMenuContext(
                    textView: textView,
                    command: command,
                    replaceLocation: session.replaceRange.lowerBound,
                    replaceLength: session.replaceRange.count
                )
                menu.addItem(item)
            }

            let point = caretPoint(in: textView, at: session.replaceRange.lowerBound)
            menu.popUp(positioning: nil, at: point, in: textView)
        }

        private func caretPoint(in textView: NSTextView, at location: Int) -> NSPoint {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                return .zero
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 0),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let origin = textView.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return NSPoint(x: rect.minX, y: rect.maxY + 2)
        }

        @objc private func slashCommandSelected(_ sender: NSMenuItem) {
            guard let ctx = sender.representedObject as? SlashMenuContext else { return }
            let textView = ctx.textView
            let nsRange = NSRange(location: ctx.replaceLocation, length: ctx.replaceLength)
            guard textView.shouldChangeText(in: nsRange, replacementString: ctx.command.snippet) else { return }
            textView.textStorage?.replaceCharacters(in: nsRange, with: ctx.command.snippet)
            textView.didChangeText()
            let caret = ctx.replaceLocation + ctx.command.caretOffset
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            runDecorations(on: textView)
        }
    }

    /// Carries everything `slashCommandSelected` needs from the menu item.
    private final class SlashMenuContext: NSObject {
        let textView: NSTextView
        let command: SlashCommand
        let replaceLocation: Int
        let replaceLength: Int

        init(textView: NSTextView, command: SlashCommand, replaceLocation: Int, replaceLength: Int) {
            self.textView = textView
            self.command = command
            self.replaceLocation = replaceLocation
            self.replaceLength = replaceLength
        }
    }
}
