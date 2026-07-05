import AppKit
import PunkRecordsInfra

/// Builds the editor's TextKit 1 stack and applies an `EditorTheme`.
///
/// Extracted from `EditorTextViewRepresentable.makeNSView` so the view/storage/
/// layout construction and theme application live in one focused, AppKit-only
/// place. Accessing a custom `NSLayoutManager` (the pill-drawing one) is what
/// keeps the editor on TextKit 1, which the editor epic deliberately chose over
/// TextKit 2. The caller wires the delegate, decorations, completion, and Emacs
/// dispatch onto the returned text view.
@MainActor
enum EditorTextKitFactory {
    /// The base typing attributes (body font + foreground) for a theme. Also
    /// used to re-seed the text when the view model reloads unedited content.
    static func baseAttributes(for theme: EditorTheme) -> [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont, .foregroundColor: theme.foreground]
    }

    /// Construct a scroll view hosting a themed `PillTextView`, seeded with
    /// `content`. Returns both so the caller can wire the text view and install
    /// it as the scroll view's document.
    static func makeEditor(
        theme: EditorTheme,
        content: String
    ) -> (scrollView: NSScrollView, textView: PillTextView) {
        // Explicit TextKit 1 stack with the pill-drawing layout manager.
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

        let attributes = baseAttributes(for: theme)
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: attributes))

        return (scrollView, textView)
    }
}
