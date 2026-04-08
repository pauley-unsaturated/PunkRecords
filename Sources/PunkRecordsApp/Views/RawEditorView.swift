import SwiftUI
import AppKit
import PunkRecordsCore
import PunkRecordsInfra

struct RawEditorView: View {
    let documentID: DocumentID
    @Environment(AppState.self) private var appState
    @State private var viewModel: DocumentEditorViewModel?

    var body: some View {
        Group {
            if let viewModel {
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
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle(viewModel?.document.title ?? "")
        .navigationSubtitle(viewModel?.isDirty == true ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        .task(id: documentID) {
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
            appState.selectedDocumentID = doc.id
        } catch {
            appState.errorMessage = "Failed to compile note: \(error.localizedDescription)"
        }
    }

    private func loadDocument() async {
        guard let repo = appState.repository else { return }
        do {
            if let doc = try await repo.document(withID: documentID) {
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

#Preview("Syntax Highlighting") {
    SyntaxHighlightPreview()
        .frame(width: 700, height: 600)
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

/// Standalone preview that renders sample markdown with syntax highlighting applied.
private struct SyntaxHighlightPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .textBackgroundColor

        textView.string = PreviewData.markdownSample

        // Create a throwaway coordinator just to apply highlighting
        let repo = FileSystemDocumentRepository(
            vaultRoot: URL(fileURLWithPath: "/tmp"),
            ignoredPaths: []
        )
        let vm = DocumentEditorViewModel(
            document: PreviewData.sampleDocument,
            repository: repo,
            searchIndex: nil
        )
        let coordinator = EditorTextViewRepresentable.Coordinator(viewModel: vm)
        coordinator.applySyntaxHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// NSViewRepresentable wrapper for NSTextView with syntax highlighting.
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

        textView.string = viewModel.document.content
        textView.delegate = context.coordinator
        context.coordinator.applySyntaxHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !viewModel.isDirty && textView.string != viewModel.document.content {
            textView.string = viewModel.document.content
            context.coordinator.applySyntaxHighlighting(to: textView)
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
        private let highlighter = RegexSyntaxHighlighter()
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
            applySyntaxHighlighting(to: textView)

            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                try? await viewModel.save()
            }
        }

        func applySyntaxHighlighting(to textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)

            // Preserve cursor position
            let selectedRanges = textView.selectedRanges

            textStorage.beginEditing()

            // Reset to base style
            let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.textColor,
            ]
            textStorage.setAttributes(baseAttrs, range: fullRange)

            // Apply highlights
            let highlights = highlighter.highlight(text)
            for highlight in highlights {
                guard highlight.range.location + highlight.range.length <= fullRange.length else { continue }
                let attrs = attributes(for: highlight.style, baseFont: baseFont)
                textStorage.addAttributes(attrs, range: highlight.range)
            }

            textStorage.endEditing()

            // Restore cursor
            textView.selectedRanges = selectedRanges
        }

        private func attributes(for style: HighlightStyle, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
            switch style {
            case .heading(let level):
                let sizes: [Int: CGFloat] = [1: 24, 2: 20, 3: 17, 4: 15, 5: 14, 6: 13]
                let size = sizes[level] ?? 14
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]
            case .bold:
                return [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
            case .italic:
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                return [.font: font]
            case .boldItalic:
                let bold = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
                let font = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
                return [.font: font]
            case .strikethrough:
                return [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            case .inlineCode:
                return [
                    .foregroundColor: NSColor.systemPink,
                    .backgroundColor: NSColor.quaternaryLabelColor,
                ]
            case .codeBlock:
                return [
                    .foregroundColor: NSColor.systemGreen,
                    .backgroundColor: NSColor.quaternaryLabelColor,
                ]
            case .codeBlockLanguage:
                return [
                    .foregroundColor: NSColor.systemTeal,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                ]
            case .blockquote:
                return [.foregroundColor: NSColor.systemMint]
            case .wikilink:
                return [
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .unresolvedWikilink:
                return [
                    .foregroundColor: NSColor.systemRed,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .link:
                return [
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .tag:
                return [.foregroundColor: NSColor.systemOrange]
            case .listMarker:
                return [.foregroundColor: NSColor.systemYellow]
            case .taskMarker:
                return [.foregroundColor: NSColor.systemPurple]
            case .horizontalRule:
                return [.foregroundColor: NSColor.separatorColor]
            }
        }
    }
}
