import Foundation

/// Pure cursor-motion logic for Emacs commands, operating on UTF-16 offsets so
/// results map directly onto `NSTextView`/`NSRange`. Kept in Core (no AppKit)
/// so the boundary math is unit-testable without a text view.
///
/// A "word" is a run of alphanumerics or underscore; everything else is a
/// separator. Paragraphs are blank-line delimited. Sentences end at `.`/`!`/`?`
/// followed by whitespace or end-of-text.
public enum EmacsMotion {
    /// New caret offset for a motion command, or nil if `command` isn't a
    /// motion this type handles.
    public static func caretDestination(for command: EmacsCommand, in text: String, caret: Int) -> Int? {
        let units = Array(text.utf16)
        let caret = clamp(caret, units.count)
        switch command {
        case .forwardWord: return forwardWord(units, caret)
        case .backwardWord: return backwardWord(units, caret)
        case .forwardParagraph: return forwardParagraph(units, caret)
        case .backwardParagraph: return backwardParagraph(units, caret)
        case .forwardSentence: return forwardSentence(units, caret)
        case .backwardSentence: return backwardSentence(units, caret)
        case .beginningOfBuffer: return 0
        case .endOfBuffer: return units.count
        default: return nil
        }
    }

    /// The UTF-16 range a word-kill command should remove, or nil if `command`
    /// isn't a word kill. The range is always ordered (lowerBound <= upperBound).
    public static func killRange(for command: EmacsCommand, in text: String, caret: Int) -> Range<Int>? {
        let units = Array(text.utf16)
        let caret = clamp(caret, units.count)
        switch command {
        case .killWord:
            let end = forwardWord(units, caret)
            return caret < end ? caret..<end : nil
        case .backwardKillWord:
            let start = backwardWord(units, caret)
            return start < caret ? start..<caret : nil
        default:
            return nil
        }
    }

    // MARK: - Word

    private static func forwardWord(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        while j < u.count, !isWord(u[j]) { j += 1 }
        while j < u.count, isWord(u[j]) { j += 1 }
        return j
    }

    private static func backwardWord(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        while j > 0, !isWord(u[j - 1]) { j -= 1 }
        while j > 0, isWord(u[j - 1]) { j -= 1 }
        return j
    }

    // MARK: - Paragraph (blank-line delimited)

    private static func forwardParagraph(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        while j < u.count, isBlankBoundary(u, j) { j += 1 }  // skip blank lines we're sitting on
        while j < u.count {
            if u[j] == nl, isBlankBoundary(u, j) { return j }
            j += 1
        }
        return u.count
    }

    private static func backwardParagraph(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        while j > 0, isBlankBoundary(u, j - 1) { j -= 1 }
        while j > 0 {
            if u[j - 1] == nl, isBlankBoundary(u, j - 1) { return j }
            j -= 1
        }
        return 0
    }

    /// True when the newline at `idx` borders a blank line (consecutive newline
    /// or the text edge), i.e. a paragraph boundary.
    private static func isBlankBoundary(_ u: [UInt16], _ idx: Int) -> Bool {
        guard idx >= 0, idx < u.count, u[idx] == nl else { return false }
        let prevBlank = idx == 0 || u[idx - 1] == nl
        let nextBlank = idx + 1 >= u.count || u[idx + 1] == nl
        return prevBlank || nextBlank
    }

    // MARK: - Sentence

    private static func forwardSentence(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        while j < u.count {
            if isSentenceEnd(u[j]) {
                j += 1
                while j < u.count, isSpace(u[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return u.count
    }

    private static func backwardSentence(_ u: [UInt16], _ i: Int) -> Int {
        var j = i
        // Step back over any leading whitespace so a repeat keeps moving.
        while j > 0, isSpace(u[j - 1]) { j -= 1 }
        while j > 0, isSentenceEnd(u[j - 1]) { j -= 1 }
        while j > 0, !isSentenceEnd(u[j - 1]) { j -= 1 }
        while j < u.count, isSpace(u[j]) { j += 1 }
        return j
    }

    // MARK: - Character classes

    private static let nl: UInt16 = 0x0A

    private static func isWord(_ u: UInt16) -> Bool {
        if u == 0x5F { return true } // underscore
        guard let scalar = Unicode.Scalar(u) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isSpace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || u == nl || u == 0x0D
    }

    private static func isSentenceEnd(_ u: UInt16) -> Bool {
        u == 0x2E || u == 0x21 || u == 0x3F // . ! ?
    }

    private static func clamp(_ value: Int, _ count: Int) -> Int {
        min(max(value, 0), count)
    }
}
