import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("TagAutocomplete Tests")
struct TagAutocompleteTests {
    @Test("Two body chars after # opens a session (third char overall)")
    func triggersAtThirdChar() {
        let s = TagAutocomplete.activeSession(in: "#sw", caretLocation: 3)
        #expect(s?.query == "sw")
        #expect(s?.replaceRange == 0..<3)
    }

    @Test("A single body char is below the trigger threshold")
    func belowThreshold() {
        #expect(TagAutocomplete.activeSession(in: "#s", caretLocation: 2) == nil)
    }

    @Test("Bare # is not a session")
    func bareHash() {
        #expect(TagAutocomplete.activeSession(in: "#", caretLocation: 1) == nil)
    }

    @Test("Query captured mid-line after whitespace")
    func midLine() {
        let text = "tagged with #swift"
        let s = TagAutocomplete.activeSession(in: text, caretLocation: text.utf16.count)
        #expect(s?.query == "swift")
        #expect(s?.replaceRange == 12..<18)
    }

    @Test("# preceded by a word char is not a tag opener")
    func hashAfterWordChar() {
        #expect(TagAutocomplete.activeSession(in: "abc#def", caretLocation: 7) == nil)
    }

    @Test("# preceded by / is not a tag opener")
    func hashAfterSlash() {
        #expect(TagAutocomplete.activeSession(in: "a/#def", caretLocation: 6) == nil)
    }

    @Test("Tag must start with a letter, not a digit")
    func digitStartRejected() {
        #expect(TagAutocomplete.activeSession(in: "#12", caretLocation: 3) == nil)
    }

    @Test("Whitespace after the query ends the session")
    func whitespaceEnds() {
        #expect(TagAutocomplete.activeSession(in: "#swift ", caretLocation: 7) == nil)
    }

    @Test("Hierarchical tags with / are valid body characters")
    func hierarchicalTag() {
        let s = TagAutocomplete.activeSession(in: "#area/work", caretLocation: 10)
        #expect(s?.query == "area/work")
    }

    @Test("Most recent # wins")
    func mostRecentHash() {
        let text = "#done now #sta"
        let s = TagAutocomplete.activeSession(in: text, caretLocation: text.utf16.count)
        #expect(s?.query == "sta")
        #expect(s?.replaceRange == 10..<14)
    }

    @Test("Insertion wraps with # and a trailing space; caret lands past it")
    func insertion() {
        #expect(TagAutocomplete.insertion(for: "swift") == "#swift ")
        #expect(TagAutocomplete.caretOffset(for: "swift") == "#swift ".utf16.count)
    }

    // MARK: - Suggestions

    @Test("Prefix matches rank ahead of substring matches")
    func prefixRanking() {
        let tags = ["swift", "swiftui", "macos-swift", "rust"]
        let out = TagAutocomplete.suggestions(matching: "swift", in: tags)
        #expect(out.first == "swift")
        #expect(out.contains("swiftui"))
        #expect(out.contains("macos-swift")) // substring match still included
        #expect(!out.contains("rust"))
    }

    @Test("Empty query returns all tags sorted")
    func emptyQueryReturnsAll() {
        let out = TagAutocomplete.suggestions(matching: "", in: ["beta", "alpha"])
        #expect(out == ["alpha", "beta"])
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        let out = TagAutocomplete.suggestions(matching: "SW", in: ["swift"])
        #expect(out == ["swift"])
    }
}
