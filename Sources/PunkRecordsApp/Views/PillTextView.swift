import AppKit
import PunkRecordsCore
import PunkRecordsInfra

/// NSTextView subclass for the editor. Opens a wikilink/tag when its pill is
/// clicked (instead of placing the caret), routes ↑/↓/Enter/Esc to the active
/// completion popover, and dispatches Emacs chords when Emacs mode is on.
/// Falls through to normal behavior everywhere else.
final class PillTextView: NSTextView {
    /// Resolves a character index to a wikilink click action, or nil if the
    /// index isn't inside a rendered pill. Set by the Coordinator.
    var resolveWikilinkClick: ((Int) -> WikilinkDecorator.ClickAction?)?
    /// Invoked with the resolved action when a pill is clicked.
    var onWikilinkClick: ((WikilinkDecorator.ClickAction) -> Void)?
    /// Resolves a character index to a `#tag` name, or nil if the index isn't
    /// inside a rendered tag pill. Set by the Coordinator.
    var resolveTagClick: ((Int) -> String?)?
    /// Invoked with the tag name when a tag pill is clicked.
    var onTagClick: ((String) -> Void)?
    /// The `[[` completion popover, when one is active. Set by the Coordinator.
    weak var completionController: WikilinkCompletionController?
    /// Whether Emacs keybindings are active. Set by the Coordinator.
    var isEmacsEnabled: () -> Bool = { false }
    /// Handles a raw Emacs chord (the Coordinator resolves prefixes + keymap);
    /// returns true if it was consumed.
    var handleEmacsChord: ((EmacsKeyChord) -> Bool)?

    override func keyDown(with event: NSEvent) {
        // Emacs dispatch: intercept Control/Meta chords before the default
        // interpretation. Skipped during IME composition and while the
        // completion popover is up (so its ↑/↓/Enter handling wins).
        if isEmacsEnabled(),
           !hasMarkedText(),
           completionController?.isVisible != true,
           let chord = EmacsKeyChord(event: event),
           handleEmacsChord?(chord) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let action = resolveWikilinkClick?(index) {
            onWikilinkClick?(action)
            return
        }
        if let tag = resolveTagClick?(index) {
            onTagClick?(tag)
            return
        }
        completionController?.hide()
        super.mouseDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let completion = completionController, completion.isVisible {
            switch selector {
            case #selector(moveUp(_:)):
                completion.moveUp(); return
            case #selector(moveDown(_:)):
                completion.moveDown(); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if completion.acceptSelection() { return }
            case #selector(cancelOperation(_:)):
                completion.hide(); return
            default:
                break
            }
        }
        super.doCommand(by: selector)
    }
}
