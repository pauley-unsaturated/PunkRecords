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

    init(
        viewModel: DocumentEditorViewModel,
        onAskAI: ((String) -> Void)? = nil,
        onSelectionChanged: ((String?) -> Void)? = nil,
        isWikilinkResolved: ((String) -> Bool)? = nil,
        onOpenWikilink: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onAskAI = onAskAI
        self.onSelectionChanged = onSelectionChanged
        self.isWikilinkResolved = isWikilinkResolved
        self.onOpenWikilink = onOpenWikilink
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
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .textColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.string = viewModel.document.content
        textView.delegate = context.coordinator

        do {
            context.coordinator.highlighter = try TreeSitterMarkdownHighlighter(textView: textView)
        } catch {
            assertionFailure("Failed to initialize TreeSitterMarkdownHighlighter: \(error)")
        }
        context.coordinator.decorator = HybridUXDecorator()
        if let isResolved = isWikilinkResolved {
            context.coordinator.wikilinkDecorator = WikilinkDecorator(isResolved: isResolved)
        }
        textView.resolveWikilinkTarget = { [weak coordinator = context.coordinator] index in
            guard let coordinator else { return nil }
            return coordinator.wikilinkDecorator?.wikilinkTarget(at: index, in: textView.string)
        }
        textView.onOpenWikilink = onOpenWikilink
        context.coordinator.runDecorations(on: textView)

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
            textView.string = viewModel.document.content
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

        /// Run the hybrid-UX and wikilink decoration passes in order.
        /// Wikilink pills go last so they win on any overlapping range.
        func runDecorations(on textView: NSTextView) {
            decorator?.decorate(textView: textView)
            wikilinkDecorator?.decorate(textView: textView)
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

            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                try? await viewModel.save()
            }
        }
    }
}
