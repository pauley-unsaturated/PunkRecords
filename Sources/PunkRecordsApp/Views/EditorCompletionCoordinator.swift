import AppKit
import PunkRecordsCore

/// Owns the editor's inline completion popover session — the `[[` wikilink and
/// `#` tag autocomplete. The pure decisions (which trigger is active at the
/// caret, and what edit an accepted title produces) live in Core's
/// `EditorCompletion`; this type owns the AppKit popover, the suggestion
/// providers, and the text-storage edit.
///
/// Extracted from `EditorTextViewRepresentable.Coordinator` so the completion
/// session lifecycle is a focused collaborator rather than tangled into the
/// text-view delegate.
@MainActor
final class EditorCompletionCoordinator {
    /// The caret-anchored popover UI. nil when no completion providers are
    /// configured (e.g. previews), in which case `update` is a no-op.
    var controller: WikilinkCompletionController?
    /// Returns candidate note titles for a `[[` query; nil disables the trigger.
    var wikilinkCompletions: ((String) -> [String])?
    /// Returns candidate tag names for a `#` query; nil disables the trigger.
    var tagCompletions: ((String) -> [String])?
    /// Invoked after an accepted completion has edited the text storage, so the
    /// owner can mirror the new text + re-decorate. Set by the coordinator.
    var afterAccept: ((NSTextView) -> Void)?

    /// The active session, or nil when the popover is hidden. Exposed for tests
    /// and mirrored from Core's pure resolution.
    private(set) var session: EditorCompletion.Session?

    /// Show/update/hide the popover based on the caret. A no-op during IME
    /// composition (marked text), which also clears any active session so a
    /// stale popover never lingers over composed text.
    func update(in textView: NSTextView) {
        guard let controller, !textView.hasMarkedText() else {
            controller?.hide()
            session = nil
            return
        }
        let caret = textView.selectedRange().location
        guard let session = EditorCompletion.activeSession(
            in: textView.string,
            caretLocation: caret,
            wikilinkEnabled: wikilinkCompletions != nil,
            tagEnabled: tagCompletions != nil
        ) else {
            controller.hide()
            self.session = nil
            return
        }
        self.session = session
        let titles = suggestions(for: session)
        let rect = caretScreenRect(in: textView, at: session.replaceRange.lowerBound)
        controller.show(titles: titles, at: rect, relativeTo: textView.window)
    }

    private func suggestions(for session: EditorCompletion.Session) -> [String] {
        switch session.kind {
        case .wikilink: return wikilinkCompletions?(session.query) ?? []
        case .tag: return tagCompletions?(session.query) ?? []
        }
    }

    /// Insert the accepted completion with its trigger's syntax (`[[title]]` or
    /// `#tag `), replacing the session range, then position the caret and notify
    /// the owner via `afterAccept`.
    func accept(_ title: String, in textView: NSTextView) {
        guard let session else { return }
        let edit = EditorCompletion.edit(accepting: title, for: session)
        let nsRange = NSRange(location: edit.replaceRange.lowerBound, length: edit.replaceRange.count)
        guard textView.shouldChangeText(in: nsRange, replacementString: edit.insertion) else { return }
        textView.textStorage?.replaceCharacters(in: nsRange, with: edit.insertion)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: edit.caretLocation, length: 0))
        self.session = nil
        afterAccept?(textView)
    }

    /// Caret rect for `location`, converted to screen coordinates so the
    /// completion panel can anchor beneath it.
    private func caretScreenRect(in textView: NSTextView, at location: Int) -> NSRect {
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
        let inWindow = textView.convert(rect, to: nil)
        return textView.window?.convertToScreen(inWindow) ?? inWindow
    }
}
