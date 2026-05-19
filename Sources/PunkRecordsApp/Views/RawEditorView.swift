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

/// NSViewRepresentable wrapper for NSTextView with tree-sitter syntax highlighting.
struct EditorTextViewRepresentable: NSViewRepresentable {
    let viewModel: DocumentEditorViewModel
    var onAskAI: ((String) -> Void)?
    var onSelectionChanged: ((String?) -> Void)?

    init(viewModel: DocumentEditorViewModel, onAskAI: ((String) -> Void)? = nil, onSelectionChanged: ((String?) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onAskAI = onAskAI
        self.onSelectionChanged = onSelectionChanged
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

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

        textView.string = viewModel.document.content
        textView.delegate = context.coordinator

        do {
            context.coordinator.highlighter = try TreeSitterMarkdownHighlighter(textView: textView)
        } catch {
            assertionFailure("Failed to initialize TreeSitterMarkdownHighlighter: \(error)")
        }
        context.coordinator.decorator = HybridUXDecorator()
        context.coordinator.decorator?.decorate(textView: textView)

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
            context.coordinator.decorator?.decorate(textView: textView)
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
        private var debounceTask: Task<Void, Never>?

        init(viewModel: DocumentEditorViewModel, onAskAI: ((String) -> Void)? = nil) {
            self.viewModel = viewModel
            self.onAskAI = onAskAI
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
            decorator?.decorate(textView: textView)
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
            decorator?.decorate(textView: textView)

            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                try? await viewModel.save()
            }
        }
    }
}
