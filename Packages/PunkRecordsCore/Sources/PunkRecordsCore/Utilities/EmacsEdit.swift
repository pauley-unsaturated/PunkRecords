import Foundation

/// Pure text transformations for Emacs editing commands (case changes and word
/// transposition). Each returns the UTF-16 range to replace, the replacement
/// text, and the resulting caret offset — so the editor layer just applies it.
/// Kept in Core (no AppKit) so the logic is unit-testable.
public enum EmacsEdit {
    public struct Edit: Equatable, Sendable {
        public let range: Range<Int>
        public let replacement: String
        public let caret: Int

        public init(range: Range<Int>, replacement: String, caret: Int) {
            self.range = range
            self.replacement = replacement
            self.caret = caret
        }
    }

    /// Transform the case of the word at/after the caret (M-c/M-u/M-l), leaving
    /// the caret after the word. Returns nil for non-case commands or when
    /// there's no word ahead.
    public static func caseEdit(_ command: EmacsCommand, in text: String, caret: Int) -> Edit? {
        let units = Array(text.utf16)
        let caret = clamp(caret, units.count)
        guard let span = nextWord(units, from: caret) else { return nil }
        let word = string(units, span)
        let replacement: String
        switch command {
        case .upcaseWord: replacement = word.uppercased()
        case .downcaseWord: replacement = word.lowercased()
        case .capitalizeWord: replacement = capitalizeFirst(word)
        default: return nil
        }
        return Edit(range: span, replacement: replacement, caret: span.upperBound)
    }

    /// Transpose the word before the caret with the word after it (M-t),
    /// leaving the caret after the now-forward word. Returns nil when there
    /// aren't two words to swap.
    public static func transposeWords(in text: String, caret: Int) -> Edit? {
        let units = Array(text.utf16)
        let caret = clamp(caret, units.count)
        guard let second = nextWord(units, from: caret) else { return nil }
        guard let first = previousWord(units, before: second.lowerBound) else { return nil }
        guard first.upperBound <= second.lowerBound else { return nil }

        let word1 = string(units, first)
        let word2 = string(units, second)
        let middle = string(units, first.upperBound..<second.lowerBound)
        return Edit(
            range: first.lowerBound..<second.upperBound,
            replacement: word2 + middle + word1,
            caret: second.upperBound
        )
    }

    // MARK: - Word spans

    /// The range of the next word at/after `i`, or nil if none remains.
    private static func nextWord(_ u: [UInt16], from i: Int) -> Range<Int>? {
        var start = i
        while start < u.count, !isWord(u[start]) { start += 1 }
        guard start < u.count else { return nil }
        var end = start
        while end < u.count, isWord(u[end]) { end += 1 }
        return start..<end
    }

    /// The range of the last word ending at/before `i`, or nil if none.
    private static func previousWord(_ u: [UInt16], before i: Int) -> Range<Int>? {
        var end = i
        while end > 0, !isWord(u[end - 1]) { end -= 1 }
        guard end > 0 else { return nil }
        var start = end
        while start > 0, isWord(u[start - 1]) { start -= 1 }
        return start..<end
    }

    private static func string(_ u: [UInt16], _ range: Range<Int>) -> String {
        String(utf16CodeUnits: Array(u[range]), count: range.count)
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    private static func isWord(_ u: UInt16) -> Bool {
        if u == 0x5F { return true }
        guard let scalar = Unicode.Scalar(u) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func clamp(_ value: Int, _ count: Int) -> Int {
        min(max(value, 0), count)
    }
}
