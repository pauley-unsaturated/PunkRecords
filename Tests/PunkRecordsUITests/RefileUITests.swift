import XCTest

/// Golden-path UI coverage for the ⌘⇧M refile picker (PUNK-7a2): the caret
/// gate, a cross-note move, and the link-update confirmation dialog. The pure
/// move/link logic is unit-tested in Core; these exercise the wiring end-to-end.
@MainActor
final class RefileUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load")
    }

    // MARK: - Helpers

    private var editor: XCUIElement { app.textViews["editorTextView"] }

    /// Open a note from the sidebar and wait for the editor to load it.
    private func openNote(_ title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) should be in the sidebar")
        row.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "editor should appear for \(title)")
    }

    /// Put the caret at the end of the document (inside the last heading's
    /// section), then invoke refile.
    private func openRefilePickerFromEnd() {
        editor.click()
        app.typeKey(.downArrow, modifierFlags: [.command])  // ⌘↓ → document end
        app.typeKey("m", modifierFlags: [.command, .shift]) // ⌘⇧M
    }

    private func waitForValue(_ element: XCUIElement, contains substring: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "value CONTAINS %@", substring)
        let exp = expectation(for: predicate, evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
                       "expected editor value to contain “\(substring)”")
    }

    private func waitForValue(_ element: XCUIElement, lacks substring: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "NOT (value CONTAINS %@)", substring)
        let exp = expectation(for: predicate, evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
                       "expected editor value to no longer contain “\(substring)”")
    }

    // MARK: - Tests

    func testRefilePickerOpensWhenCaretOnHeading() throws {
        openNote("Refile Plain")
        openRefilePickerFromEnd()
        XCTAssertTrue(app.textFields["refileField"].waitForExistence(timeout: 3),
                      "⌘⇧M with the caret on a heading should open the refile picker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.textFields["refileField"].waitForExistence(timeout: 1),
                       "Escape should dismiss the picker")
    }

    func testRefileMovesHeadingToAnotherNote() throws {
        openNote("Refile Plain")
        openRefilePickerFromEnd()

        let field = app.textFields["refileField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("destbucket")            // fuzzy → "Refile Dest ▸ Bucket"
        app.typeKey(.return, modifierFlags: [])

        // Refile selects the destination; its content now holds the moved heading.
        waitForValue(editor, contains: "Movable")
        waitForValue(editor, contains: "movable body")

        // The source note no longer contains the heading.
        openNote("Refile Plain")
        waitForValue(editor, lacks: "Movable")
    }

    func testRefileLinkDialogAppearsAndUpdates() throws {
        openNote("Refile Linked")
        openRefilePickerFromEnd()

        let field = app.textFields["refileField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("destbucket")
        app.typeKey(.return, modifierFlags: [])

        // A [[Refile Linked#Linked Section]] link exists in Linker, so the move
        // surfaces the confirmation dialog.
        let updateButton = app.buttons["Update Links & Move"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 3),
                      "Moving a linked heading should prompt to update links")
        updateButton.click()

        // The link in Linker should now point at the destination note.
        openNote("Linker")
        waitForValue(editor, contains: "Refile Dest#Linked Section")
    }
}
