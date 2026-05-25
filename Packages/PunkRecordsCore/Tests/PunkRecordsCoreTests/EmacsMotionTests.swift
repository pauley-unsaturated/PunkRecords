import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("EmacsMotion Tests")
struct EmacsMotionTests {
    private func dest(_ command: EmacsCommand, _ text: String, _ caret: Int) -> Int? {
        EmacsMotion.caretDestination(for: command, in: text, caret: caret)
    }

    // MARK: - Word motion

    @Test("forwardWord lands after the next word")
    func forwardWord() {
        // "the quick" — caret at 0 lands after "the" (index 3).
        #expect(dest(.forwardWord, "the quick", 0) == 3)
        // from within whitespace, skip then consume next word.
        #expect(dest(.forwardWord, "the quick", 3) == 9)
    }

    @Test("backwardWord lands at the start of the previous word")
    func backwardWord() {
        #expect(dest(.backwardWord, "the quick", 9) == 4)
        #expect(dest(.backwardWord, "the quick", 3) == 0)
    }

    @Test("Word motion treats punctuation as separators")
    func wordMotionPunctuation() {
        // "foo.bar" — from 0, forwardWord stops after "foo" (3).
        #expect(dest(.forwardWord, "foo.bar()", 0) == 3)
    }

    @Test("Underscore is part of a word")
    func underscoreIsWord() {
        #expect(dest(.forwardWord, "snake_case end", 0) == 10)
    }

    @Test("forwardWord at end of text stays at end")
    func forwardWordAtEnd() {
        #expect(dest(.forwardWord, "abc", 3) == 3)
    }

    // MARK: - Buffer

    @Test("Buffer motions jump to the ends")
    func bufferMotions() {
        let text = "line one\nline two"
        #expect(dest(.beginningOfBuffer, text, 10) == 0)
        #expect(dest(.endOfBuffer, text, 0) == (text as NSString).length)
    }

    // MARK: - Paragraph

    @Test("forwardParagraph moves to the blank line between paragraphs")
    func forwardParagraph() {
        let text = "para one\nstill one\n\npara two"
        // The blank-line boundary is the newline at index 19 (the empty line).
        let d = dest(.forwardParagraph, text, 0)
        #expect(d != nil)
        // Lands at the paragraph-ending newline (18) up to the blank line (19),
        // i.e. past "still one" and before "para two" (20).
        #expect(d! >= 18)
        #expect(d! <= 20)
    }

    @Test("backwardParagraph moves toward the start")
    func backwardParagraph() {
        let text = "para one\n\npara two"
        let d = dest(.backwardParagraph, text, (text as NSString).length)
        #expect(d != nil)
        #expect(d! <= 10) // at/after the blank line, before "para two"
    }

    // MARK: - Sentence

    @Test("forwardSentence lands after the terminator and trailing spaces")
    func forwardSentence() {
        let text = "One sentence. Another one."
        // From 0, lands after ". " → index 14 (start of "Another").
        #expect(dest(.forwardSentence, text, 0) == 14)
    }

    @Test("backwardSentence moves to the start of the sentence")
    func backwardSentence() {
        let text = "One sentence. Another one."
        let end = (text as NSString).length
        #expect(dest(.backwardSentence, text, end) == 14)
    }

    // MARK: - Kill ranges

    @Test("killWord range covers the next word")
    func killWordRange() {
        #expect(EmacsMotion.killRange(for: .killWord, in: "hello world", caret: 0) == 0..<5)
    }

    @Test("backwardKillWord range covers the previous word")
    func backwardKillWordRange() {
        #expect(EmacsMotion.killRange(for: .backwardKillWord, in: "hello world", caret: 11) == 6..<11)
    }

    @Test("Non-motion / non-kill commands return nil")
    func nonMotionReturnsNil() {
        #expect(dest(.setMark, "abc", 0) == nil)
        #expect(EmacsMotion.killRange(for: .forwardWord, in: "abc", caret: 0) == nil)
    }

    @Test("Out-of-range caret is clamped")
    func caretClamped() {
        #expect(dest(.forwardWord, "abc", 99) == 3)
        #expect(dest(.backwardWord, "abc", -5) == 0)
    }
}
