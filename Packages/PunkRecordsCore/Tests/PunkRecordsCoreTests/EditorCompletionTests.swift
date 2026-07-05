import Foundation
import Testing
@testable import PunkRecordsCore

/// Tests the coordination seam extracted from the editor coordinator: which
/// trigger owns the caret (wikilinks vs tags, and precedence), and the edit an
/// accepted title produces. The underlying trigger detection and insertion
/// strings are already covered by `WikilinkAutocompleteTests` / `TagAutocomplete
/// Tests`, so these focus on the resolution/precedence/accept coordination only.
@Suite("EditorCompletion Tests")
struct EditorCompletionTests {
    // MARK: - Session resolution

    @Test("No trigger at caret resolves to no session")
    func noTrigger() {
        let session = EditorCompletion.activeSession(
            in: "hello world", caretLocation: 11,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(session == nil)
    }

    @Test("Open `[[` resolves a wikilink session")
    func wikilinkSession() {
        let session = EditorCompletion.activeSession(
            in: "[[fo", caretLocation: 4,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(session?.kind == .wikilink)
        #expect(session?.query == "fo")
        #expect(session?.replaceRange == 0..<4)
    }

    @Test("`#` plus two letters resolves a tag session")
    func tagSession() {
        let session = EditorCompletion.activeSession(
            in: "#mus", caretLocation: 4,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(session?.kind == .tag)
        #expect(session?.query == "mus")
        #expect(session?.replaceRange == 0..<4)
    }

    // MARK: - Precedence

    @Test("Wikilink takes precedence when both triggers match")
    func wikilinkWinsOverTag() {
        // `[[#ab` matches BOTH: the `[[` opener (query "#ab") and the `#ab` tag.
        let session = EditorCompletion.activeSession(
            in: "[[#ab", caretLocation: 5,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(session?.kind == .wikilink)
        #expect(session?.query == "#ab")
    }

    @Test("Disabling the wikilink trigger falls through to the tag")
    func wikilinkDisabledFallsToTag() {
        let session = EditorCompletion.activeSession(
            in: "[[#ab", caretLocation: 5,
            wikilinkEnabled: false, tagEnabled: true
        )
        #expect(session?.kind == .tag)
        #expect(session?.query == "ab")
    }

    @Test("Disabling the tag trigger suppresses a tag session")
    func tagDisabled() {
        let session = EditorCompletion.activeSession(
            in: "#mus", caretLocation: 4,
            wikilinkEnabled: true, tagEnabled: false
        )
        #expect(session == nil)
    }

    // MARK: - State transitions

    @Test("Closing the bracket ends the wikilink session")
    func closingBracketDismisses() {
        let open = EditorCompletion.activeSession(
            in: "[[fo", caretLocation: 4,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(open?.kind == .wikilink)
        // Once a `]` lands after the caret span, no session is active.
        let closed = EditorCompletion.activeSession(
            in: "[[fo]", caretLocation: 5,
            wikilinkEnabled: true, tagEnabled: true
        )
        #expect(closed == nil)
    }

    // MARK: - Accept edits

    @Test("Accepting a wikilink inserts `[[title]]` and reports the caret")
    func acceptWikilink() {
        let session = EditorCompletion.Session(kind: .wikilink, query: "fo", replaceRange: 0..<4)
        let edit = EditorCompletion.edit(accepting: "Foo Bar", for: session)
        #expect(edit.insertion == "[[Foo Bar]]")
        #expect(edit.replaceRange == 0..<4)
        #expect(edit.caretLocation == "[[Foo Bar]]".utf16.count) // lowerBound 0 + full length
    }

    @Test("Accepting a tag inserts `#tag ` and lands the caret past the space")
    func acceptTag() {
        let session = EditorCompletion.Session(kind: .tag, query: "mus", replaceRange: 2..<6)
        let edit = EditorCompletion.edit(accepting: "music", for: session)
        #expect(edit.insertion == "#music ")
        #expect(edit.replaceRange == 2..<6)
        #expect(edit.caretLocation == 2 + "#music ".utf16.count)
    }
}
