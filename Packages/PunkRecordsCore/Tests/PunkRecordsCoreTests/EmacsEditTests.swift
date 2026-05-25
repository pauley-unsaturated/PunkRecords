import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("EmacsEdit Tests")
struct EmacsEditTests {
    // MARK: - Case

    @Test("upcaseWord uppercases the next word")
    func upcase() {
        let edit = EmacsEdit.caseEdit(.upcaseWord, in: "hello world", caret: 0)
        #expect(edit?.range == 0..<5)
        #expect(edit?.replacement == "HELLO")
        #expect(edit?.caret == 5)
    }

    @Test("downcaseWord lowercases the next word")
    func downcase() {
        let edit = EmacsEdit.caseEdit(.downcaseWord, in: "HELLO world", caret: 0)
        #expect(edit?.replacement == "hello")
    }

    @Test("capitalizeWord capitalizes first, lowercases rest")
    func capitalize() {
        let edit = EmacsEdit.caseEdit(.capitalizeWord, in: "hELLO", caret: 0)
        #expect(edit?.replacement == "Hello")
    }

    @Test("Case command skips leading separators to the next word")
    func skipsSeparators() {
        let edit = EmacsEdit.caseEdit(.upcaseWord, in: "  foo", caret: 0)
        #expect(edit?.range == 2..<5)
        #expect(edit?.replacement == "FOO")
    }

    @Test("No word ahead returns nil")
    func noWordAhead() {
        #expect(EmacsEdit.caseEdit(.upcaseWord, in: "abc   ", caret: 3) == nil)
    }

    @Test("Non-case command returns nil")
    func nonCaseNil() {
        #expect(EmacsEdit.caseEdit(.forwardWord, in: "abc", caret: 0) == nil)
    }

    // MARK: - Transpose

    @Test("transposeWords swaps the words around the caret")
    func transpose() {
        // caret between the two words.
        let edit = EmacsEdit.transposeWords(in: "foo bar", caret: 3)
        #expect(edit?.range == 0..<7)
        #expect(edit?.replacement == "bar foo")
        #expect(edit?.caret == 7)
    }

    @Test("transposeWords preserves the separator between words")
    func transposePreservesSeparator() {
        let edit = EmacsEdit.transposeWords(in: "alpha, beta", caret: 6)
        #expect(edit?.replacement == "beta, alpha")
    }

    @Test("transposeWords returns nil without two words")
    func transposeNeedsTwoWords() {
        #expect(EmacsEdit.transposeWords(in: "onlyone", caret: 0) == nil)
        #expect(EmacsEdit.transposeWords(in: "", caret: 0) == nil)
    }
}
