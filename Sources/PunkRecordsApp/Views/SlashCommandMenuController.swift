import AppKit
import PunkRecordsCore

/// Owns the editor's `/` slash-command pop-up menu. The trigger detection and
/// insertion edits live in Core (`SlashCommandLibrary` / `SlashCommand`); this
/// type builds the `NSMenu`, pops it at the caret, and applies the chosen edit
/// to the text storage.
///
/// Extracted from `EditorTextViewRepresentable.Coordinator` so the slash-menu
/// lifecycle is a focused collaborator rather than tangled into the text-view
/// delegate.
@MainActor
final class SlashCommandMenuController: NSObject {
    /// Invoked after a command has edited the text storage, so the owner can
    /// re-decorate. Set by the coordinator.
    var afterInsert: ((NSTextView) -> Void)?

    /// Pop the menu when the caret sits on a bare `/` trigger (a lone slash at
    /// the start of a line or after whitespace). A no-op otherwise — including
    /// when a `/query` is being typed, which is not a menu trigger.
    func maybeShowMenu(in textView: NSTextView) {
        let caret = textView.selectedRange().location
        guard let replaceRange = SlashCommandLibrary.menuTrigger(
            in: textView.string,
            caretLocation: caret
        ) else { return }

        let menu = NSMenu()
        for command in SlashCommandLibrary.all {
            let item = NSMenuItem(
                title: command.title,
                action: #selector(commandSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: command.systemImage, accessibilityDescription: command.title)
            item.toolTip = command.subtitle
            item.representedObject = Context(textView: textView, command: command, replaceRange: replaceRange)
            menu.addItem(item)
        }

        let point = caretPoint(in: textView, at: replaceRange.lowerBound)
        menu.popUp(positioning: nil, at: point, in: textView)
    }

    @objc private func commandSelected(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? Context else { return }
        let textView = ctx.textView
        let nsRange = NSRange(location: ctx.replaceRange.lowerBound, length: ctx.replaceRange.count)
        let insertion = ctx.command.insertion(replacing: ctx.replaceRange)
        guard textView.shouldChangeText(in: nsRange, replacementString: insertion.text) else { return }
        textView.textStorage?.replaceCharacters(in: nsRange, with: insertion.text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: insertion.caretLocation, length: 0))
        afterInsert?(textView)
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

    /// Carries everything `commandSelected` needs from the menu item.
    private final class Context: NSObject {
        let textView: NSTextView
        let command: SlashCommand
        let replaceRange: Range<Int>

        init(textView: NSTextView, command: SlashCommand, replaceRange: Range<Int>) {
            self.textView = textView
            self.command = command
            self.replaceRange = replaceRange
        }
    }
}
