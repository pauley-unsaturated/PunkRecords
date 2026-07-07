import XCTest

/// Golden-path coverage for Live Preview marker folding (PUNK-zp1): type
/// markdown with markers, move the caret out of and back into an element, and
/// verify the SOURCE never changes and edits land at the right offsets.
///
/// Folding hides marker glyphs at zero width, but the accessibility tree reads
/// the underlying string — so XCUITest cannot see "hidden" pixels. That is by
/// design: the load-bearing invariant this test pins down is that folding is
/// glyph-only and never mutates the document or displaces the caret mapping.
/// Whether the `**` actually renders at zero width is a MANUAL visual check.
///
/// NOTE: like all PunkRecordsUITests, this requires an interactive session with
/// automation permission — a failed headless attempt wedges testmanagerd
/// machine-wide. It is compile-checked via build-for-testing, not run in
/// automated agent sessions.
@MainActor
final class LivePreviewUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load")
    }

    private var editor: XCUIElement { app.textViews["editorTextView"] }

    private func waitForValue(_ element: XCUIElement, contains substring: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "value CONTAINS %@", substring)
        let exp = expectation(for: predicate, evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
                       "expected editor value to contain “\(substring)”")
    }

    func testFoldingNeverMutatesSourceAndCaretEditsStayAligned() throws {
        app.staticTexts["Test Note"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "editor should open")
        editor.click()

        // Fresh line at the end of the document, then markdown with foldable
        // markers: bold, a link, and inline code.
        app.typeKey(.downArrow, modifierFlags: [.command]) // ⌘↓ → document end
        editor.typeText("\nAA **bold** [go](https://example.com) `code` ZZ")

        // The caret now sits at the end — OUTSIDE every element — so all the
        // markers above are folded. The raw source must still contain every
        // delimiter byte-for-byte.
        waitForValue(editor, contains: "AA **bold** [go](https://example.com) `code` ZZ")

        // Walk the caret INTO the bold element (which reveals its markers) and
        // type there. If folding mutated the string or skewed caret↔character
        // mapping, this edit would land at the wrong offset.
        // Line: A A ␣ * * b o l d * * …  → 6 × ← from line start reaches b|old.
        app.typeKey(.leftArrow, modifierFlags: [.command]) // ⌘← → line start
        for _ in 0..<6 { app.typeKey(.rightArrow, modifierFlags: []) }
        editor.typeText("X")
        waitForValue(editor, contains: "AA **bXold**")

        // Leave the element again (fold state flips back) and confirm the
        // source is still intact afterwards.
        app.typeKey(.downArrow, modifierFlags: [.command])
        waitForValue(editor, contains: "AA **bXold** [go](https://example.com) `code` ZZ")

        // Undo removes exactly the typed character — the fold/unfold cycles in
        // between must not have polluted the undo stack with extra entries.
        app.typeKey("z", modifierFlags: [.command])
        waitForValue(editor, contains: "AA **bold** [go](https://example.com) `code` ZZ")
    }
}
