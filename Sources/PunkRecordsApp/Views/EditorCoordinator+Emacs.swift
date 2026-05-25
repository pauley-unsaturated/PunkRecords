import AppKit
import PunkRecordsCore

/// Emacs command execution for the editor coordinator. The key→command mapping
/// and all boundary math live in pure, tested Core types (`EmacsKeymap`,
/// `EmacsMotion`, `EmacsKillRing`); this extension applies their results to the
/// `NSTextView` and owns the stateful mark/region/yank wiring.
extension EditorTextViewRepresentable.Coordinator {
    /// Resolve a raw chord, handling the `C-x` two-key prefix, then map the
    /// rest through `EmacsKeymap`. Returns true if the chord was consumed.
    func handleEmacsChord(_ chord: EmacsKeyChord, in textView: NSTextView) -> Bool {
        if awaitingCtrlX {
            awaitingCtrlX = false
            return performCtrlXCommand(chord, in: textView)
        }
        // `C-x` opens a prefix sequence completed by the next key.
        if chord == EmacsKeyChord(key: "x", control: true, meta: false) {
            awaitingCtrlX = true
            return true
        }
        guard let command = EmacsKeymap.command(for: chord) else { return false }
        return performEmacsCommand(command, in: textView)
    }

    /// Second key of a `C-x` sequence: `C-x C-s` saves, `C-x u` undoes. Other
    /// keys are consumed as no-ops (the sequence was deliberately initiated).
    private func performCtrlXCommand(_ chord: EmacsKeyChord, in textView: NSTextView) -> Bool {
        if chord.key == "s", chord.control {            // C-x C-s
            Task { try? await viewModel.save() }
        } else if chord.key == "u" {                    // C-x u
            textView.undoManager?.undo()
        }
        return true
    }

    /// Execute a resolved Emacs command. Returns true when the command is
    /// consumed (so the key event is not passed on for default handling).
    func performEmacsCommand(_ command: EmacsCommand, in textView: NSTextView) -> Bool {
        isPerformingEmacsEdit = true
        defer { isPerformingEmacsEdit = false }

        let selection = textView.selectedRange()
        let caret = selection.location
        switch command {
        case .forwardWord, .backwardWord, .forwardSentence, .backwardSentence,
             .forwardParagraph, .backwardParagraph, .beginningOfBuffer, .endOfBuffer:
            if let dest = EmacsMotion.caretDestination(for: command, in: textView.string, caret: pointLocation(in: textView)) {
                moveOrExtend(to: dest, in: textView)
            }
            return true

        case .killWord, .backwardKillWord:
            if let range = EmacsMotion.killRange(for: command, in: textView.string, caret: caret) {
                killAndDelete(NSRange(location: range.lowerBound, length: range.count), in: textView)
            }
            return true

        case .setMark:
            emacsMark = caret
            return true

        case .killRegion:
            if let region = activeRegion(in: textView) {
                killAndDelete(region, in: textView)
            }
            emacsMark = nil
            return true

        case .copyRegion:
            if let region = activeRegion(in: textView), region.length > 0 {
                let text = (textView.string as NSString).substring(with: region)
                killRing.kill(text)
                writeToPasteboard(text)
                textView.setSelectedRange(NSRange(location: region.location, length: 0))
            }
            emacsMark = nil
            return true

        case .yank:
            if let text = killRing.current {
                insertYank(text, replacing: selection, in: textView)
            }
            emacsMark = nil
            return true

        case .yankPop:
            if let previous = lastYankRange, let text = killRing.rotate() {
                insertYank(text, replacing: previous, in: textView)
            }
            return true

        case .keyboardQuit:
            emacsMark = nil
            lastYankRange = nil
            textView.setSelectedRange(NSRange(location: caret + selection.length, length: 0))
            return true

        case .undo:
            textView.undoManager?.undo()
            return true

        case .capitalizeWord, .upcaseWord, .downcaseWord:
            if let edit = EmacsEdit.caseEdit(command, in: textView.string, caret: caret) {
                applyEdit(edit, in: textView)
            }
            return true

        case .transposeWords:
            if let edit = EmacsEdit.transposeWords(in: textView.string, caret: caret) {
                applyEdit(edit, in: textView)
            }
            return true
        }
    }

    /// Apply a pure `EmacsEdit.Edit` (case change / transpose) to the text view.
    private func applyEdit(_ edit: EmacsEdit.Edit, in textView: NSTextView) {
        let range = NSRange(location: edit.range.lowerBound, length: edit.range.count)
        guard NSMaxRange(range) <= (textView.string as NSString).length,
              textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
    }

    /// The point (caret) used for motions — the active end of the selection.
    private func pointLocation(in textView: NSTextView) -> Int {
        let sel = textView.selectedRange()
        // With a mark set, point is the far end of the selection from the mark.
        if let mark = emacsMark, sel.length > 0 {
            return sel.location == mark ? sel.location + sel.length : sel.location
        }
        return sel.location
    }

    /// Move the caret to `dest`, or extend the selection from the mark to
    /// `dest` when a mark is active.
    private func moveOrExtend(to dest: Int, in textView: NSTextView) {
        if let mark = emacsMark {
            let lower = min(mark, dest)
            let upper = max(mark, dest)
            textView.setSelectedRange(NSRange(location: lower, length: upper - lower))
        } else {
            textView.setSelectedRange(NSRange(location: dest, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// The region to kill/copy: the live selection if non-empty, else the span
    /// between the mark and the caret.
    private func activeRegion(in textView: NSTextView) -> NSRange? {
        let sel = textView.selectedRange()
        if sel.length > 0 { return sel }
        guard let mark = emacsMark else { return nil }
        let lower = min(mark, sel.location)
        let upper = max(mark, sel.location)
        return NSRange(location: lower, length: upper - lower)
    }

    /// Push `range`'s text onto the kill-ring + pasteboard, then delete it.
    private func killAndDelete(_ range: NSRange, in textView: NSTextView) {
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        let text = (textView.string as NSString).substring(with: range)
        killRing.kill(text)
        writeToPasteboard(text)
        guard textView.shouldChangeText(in: range, replacementString: "") else { return }
        textView.textStorage?.replaceCharacters(in: range, with: "")
        textView.didChangeText()
    }

    /// Replace `range` with `text` and record the inserted span so a following
    /// M-y (yank-pop) can swap it for an older kill.
    private func insertYank(_ text: String, replacing range: NSRange, in textView: NSTextView) {
        guard NSMaxRange(range) <= (textView.string as NSString).length,
              textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        let inserted = NSRange(location: range.location, length: (text as NSString).length)
        lastYankRange = inserted
        textView.setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
    }

    private func writeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
