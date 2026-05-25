import Foundation

/// The vocabulary of Emacs editor commands. Mapping lives here (pure,
/// testable); execution is wired in the editor's AppKit layer.
///
/// macOS's `NSTextView` already provides the common Control motions natively
/// (C-a/C-e/C-f/C-b/C-n/C-p/C-k/C-d/C-t/C-o and a C-y yank), so this vocabulary
/// covers only the commands those bindings *don't* — chiefly the Meta layer and
/// the Emacs mark/kill-ring/quit commands.
public enum EmacsCommand: Equatable, Sendable {
    // Motions (implemented in the motions task)
    case forwardWord
    case backwardWord
    case backwardSentence
    case forwardSentence
    case backwardParagraph
    case forwardParagraph
    case beginningOfBuffer
    case endOfBuffer

    // Mark, region & kill-ring (implemented in the kill-ring task)
    case setMark
    case keyboardQuit
    case killRegion
    case copyRegion
    case yank
    case yankPop
    case killWord
    case backwardKillWord

    // Editing (implemented in the editing-commands task)
    case undo
    case capitalizeWord
    case upcaseWord
    case downcaseWord
    case transposeWords
}

/// A modifier+key chord, decoupled from AppKit so the keymap is unit-testable.
/// `key` is the base character ignoring modifiers, lowercased (e.g. "f", " ",
/// "\u{7f}" for DEL, "<"). `meta` is Emacs Meta — the Option/Alt key on macOS.
public struct EmacsKeyChord: Hashable, Sendable {
    public let key: String
    public let control: Bool
    public let meta: Bool

    public init(key: String, control: Bool, meta: Bool) {
        self.key = key
        self.control = control
        self.meta = meta
    }

    fileprivate static func meta(_ key: String) -> EmacsKeyChord {
        EmacsKeyChord(key: key, control: false, meta: true)
    }

    fileprivate static func control(_ key: String) -> EmacsKeyChord {
        EmacsKeyChord(key: key, control: true, meta: false)
    }
}

/// Pure mapping from a key chord to an `EmacsCommand`. Returns nil for chords
/// that aren't Emacs commands (or are already handled natively by NSTextView),
/// so the caller passes them through unchanged.
///
/// macOS handles the common Control motions itself; this table only covers the
/// Meta layer plus the Emacs mark/kill-ring/quit/undo chords.
public enum EmacsKeymap {
    private static let table: [EmacsKeyChord: EmacsCommand] = [
        // Meta motions
        .meta("f"): .forwardWord,
        .meta("b"): .backwardWord,
        .meta("a"): .backwardSentence,
        .meta("e"): .forwardSentence,
        .meta("{"): .backwardParagraph,
        .meta("}"): .forwardParagraph,
        .meta("<"): .beginningOfBuffer,
        .meta(">"): .endOfBuffer,
        // Meta kills / case / transpose
        .meta("d"): .killWord,
        .meta("\u{7f}"): .backwardKillWord,  // M-DEL
        .meta("w"): .copyRegion,
        .meta("y"): .yankPop,
        .meta("c"): .capitalizeWord,
        .meta("u"): .upcaseWord,
        .meta("l"): .downcaseWord,
        .meta("t"): .transposeWords,
        // Control chords NSTextView doesn't map to Emacs semantics
        .control(" "): .setMark,        // C-Space
        .control("g"): .keyboardQuit,   // C-g
        .control("w"): .killRegion,     // C-w
        .control("y"): .yank,           // C-y (use our kill-ring)
        .control("/"): .undo,
        .control("_"): .undo,
    ]

    public static func command(for chord: EmacsKeyChord) -> EmacsCommand? {
        table[chord]
    }
}
