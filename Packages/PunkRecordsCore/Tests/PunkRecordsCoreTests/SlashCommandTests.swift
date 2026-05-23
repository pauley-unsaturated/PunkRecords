import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SlashCommandLibrary Tests")
struct SlashCommandTests {
    // MARK: - Library

    @Test("Library ships at least 8 built-in commands")
    func atLeastEight() {
        #expect(SlashCommandLibrary.all.count >= 8)
    }

    @Test("Command ids are unique")
    func uniqueIDs() {
        let ids = SlashCommandLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Caret offset never exceeds the snippet length")
    func caretOffsetWithinSnippet() {
        for cmd in SlashCommandLibrary.all {
            #expect(cmd.caretOffset <= cmd.snippet.utf16.count,
                    "\(cmd.id): caret \(cmd.caretOffset) > snippet \(cmd.snippet.utf16.count)")
        }
    }

    // MARK: - Filtering

    @Test("Empty query returns everything")
    func emptyQueryReturnsAll() {
        #expect(SlashCommandLibrary.filter("").count == SlashCommandLibrary.all.count)
    }

    @Test("Prefix on id matches")
    func idPrefix() {
        let results = SlashCommandLibrary.filter("h1")
        #expect(results.contains { $0.id == "h1" })
    }

    @Test("Subsequence on title matches")
    func titleSubsequence() {
        let results = SlashCommandLibrary.filter("head")
        #expect(results.allSatisfy { $0.title.lowercased().contains("head") })
        #expect(!results.isEmpty)
    }

    @Test("No match returns empty")
    func noMatch() {
        #expect(SlashCommandLibrary.filter("zzzzz").isEmpty)
    }

    // MARK: - Trigger detection

    @Test("Slash at start of text triggers")
    func slashAtStart() {
        let session = SlashCommandLibrary.activeSession(in: "/head", caretLocation: 5)
        #expect(session?.query == "head")
        #expect(session?.replaceRange == 0..<5)
    }

    @Test("Slash after a space triggers")
    func slashAfterSpace() {
        let text = "hello /co"
        let session = SlashCommandLibrary.activeSession(in: text, caretLocation: 9)
        #expect(session?.query == "co")
        #expect(session?.replaceRange == 6..<9)
    }

    @Test("Slash after a newline triggers")
    func slashAfterNewline() {
        let text = "line one\n/qu"
        let session = SlashCommandLibrary.activeSession(in: text, caretLocation: 12)
        #expect(session?.query == "qu")
    }

    @Test("Slash mid-word (e.g. a path) does NOT trigger")
    func slashMidWord() {
        let text = "path/to"
        let session = SlashCommandLibrary.activeSession(in: text, caretLocation: 7)
        #expect(session == nil)
    }

    @Test("Whitespace between slash and caret cancels the session")
    func whitespaceCancels() {
        let text = "/head now"
        let session = SlashCommandLibrary.activeSession(in: text, caretLocation: 9)
        #expect(session == nil)
    }

    @Test("Empty query right after slash is a valid session")
    func emptyQuerySession() {
        let session = SlashCommandLibrary.activeSession(in: "/", caretLocation: 1)
        #expect(session?.query == "")
        #expect(session?.replaceRange == 0..<1)
    }

    @Test("No slash means no session")
    func noSlash() {
        #expect(SlashCommandLibrary.activeSession(in: "just text", caretLocation: 9) == nil)
    }
}
