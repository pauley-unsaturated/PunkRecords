import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("WikilinkAutocomplete Tests")
struct WikilinkAutocompleteTests {
    @Test("Caret right after [[ is an active session with empty query")
    func emptyQuery() {
        let s = WikilinkAutocomplete.activeSession(in: "[[", caretLocation: 2)
        #expect(s?.query == "")
        #expect(s?.replaceRange == 0..<2)
    }

    @Test("Partial query after [[ is captured")
    func partialQuery() {
        let text = "see [[Fo"
        let s = WikilinkAutocomplete.activeSession(in: text, caretLocation: 8)
        #expect(s?.query == "Fo")
        #expect(s?.replaceRange == 4..<8)
    }

    @Test("Query may contain spaces (note titles do)")
    func queryWithSpaces() {
        let text = "[[Foo Bar Ba"
        let s = WikilinkAutocomplete.activeSession(in: text, caretLocation: 12)
        #expect(s?.query == "Foo Bar Ba")
    }

    @Test("Closing ] ends the session")
    func closedLinkNoSession() {
        let text = "[[Foo]]"
        #expect(WikilinkAutocomplete.activeSession(in: text, caretLocation: 7) == nil)
    }

    @Test("Newline between [[ and caret cancels the session")
    func newlineCancels() {
        let text = "[[Foo\nbar"
        #expect(WikilinkAutocomplete.activeSession(in: text, caretLocation: 9) == nil)
    }

    @Test("Alias separator | ends the matchable session")
    func pipeCancels() {
        let text = "[[Foo|al"
        #expect(WikilinkAutocomplete.activeSession(in: text, caretLocation: 8) == nil)
    }

    @Test("Most recent [[ wins when an earlier link is closed")
    func mostRecentOpener() {
        let text = "[[Done]] and [[Sta"
        let s = WikilinkAutocomplete.activeSession(in: text, caretLocation: 18)
        #expect(s?.query == "Sta")
        #expect(s?.replaceRange == 13..<18)
    }

    @Test("No [[ means no session")
    func noOpener() {
        #expect(WikilinkAutocomplete.activeSession(in: "just text", caretLocation: 9) == nil)
    }

    @Test("Single [ is not a trigger")
    func singleBracket() {
        #expect(WikilinkAutocomplete.activeSession(in: "a [x", caretLocation: 4) == nil)
    }

    @Test("Insertion wraps the title in brackets and caret lands past them")
    func insertion() {
        #expect(WikilinkAutocomplete.insertion(for: "Foo Note") == "[[Foo Note]]")
        #expect(WikilinkAutocomplete.caretOffset(for: "Foo Note") == "[[Foo Note]]".utf16.count)
    }
}
