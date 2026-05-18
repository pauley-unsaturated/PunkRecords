import XCTest

/// Covers the sidebar file-ops added in the May 16 batch:
/// - New Note button actually adds a row (regression test for the staleness bug)
/// - Return-key inline rename round-trips through disk and back into the sidebar
/// - Cmd+Shift+P toggles between editor and MarkdownPreviewView
@MainActor
final class SidebarFileOpsUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()

        // The UI-test vault is recreated on each launch and contains a single
        // "Test Note" doc — wait for it before each case.
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load with Test Note visible")
    }

    func testNewNoteButtonCreatesSidebarRow() throws {
        XCTAssertFalse(app.staticTexts["Untitled"].exists,
                       "Fresh UI-test vault should not contain an Untitled row before clicking +")

        let newNoteButton = app.buttons["New Note"]
        XCTAssertTrue(newNoteButton.waitForExistence(timeout: 5),
                      "New Note toolbar button should be present")
        newNoteButton.click()

        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 5),
                      "Sidebar should reactively show the newly created Untitled note")
    }

    func testReturnKeyRenamesSidebarRow() throws {
        app.staticTexts["Test Note"].click()

        // Return on the selected row enters inline rename mode.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let renameField = app.textFields["renameField"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3),
                      "Rename TextField should appear after Return on the selected row")

        // The field is pre-populated with the filename ("test-note"); replace it.
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Renamed Note")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Renamed Note"].waitForExistence(timeout: 5),
                      "Renamed row should appear in the sidebar")
        XCTAssertFalse(app.staticTexts["Test Note"].exists,
                       "Original Test Note row should no longer be present")
    }

    func testCmdShiftFFocusesSidebarSearch() throws {
        let field = app.textFields["sidebarSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "Sidebar search field should be present in the vault browser")

        // Verify focus indirectly: typing after Cmd+Shift+F should land in the field.
        app.typeKey("f", modifierFlags: [.command, .shift])
        app.typeText("X")
        XCTAssertEqual(field.value as? String, "X",
                       "Cmd+Shift+F should focus the field so subsequent typing lands there")
    }

    func testSidebarSearchFiltersRows() throws {
        // Vault has two notes: "Test Note" and "Scratch Note"
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scratch Note"].exists)

        let field = app.textFields["sidebarSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: [.command, .shift])
        app.typeText("Scratch")

        // After filtering, only Scratch Note remains in the sidebar.
        XCTAssertTrue(app.staticTexts["Scratch Note"].waitForExistence(timeout: 3))

        let testRowVisible = app.staticTexts["Test Note"].exists
        XCTAssertFalse(testRowVisible,
                       "Test Note should be filtered out when query is 'Scratch'")

        // Escape clears the filter and Test Note returns.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 3),
                      "Escape on a non-empty filter should clear it and restore all rows")
    }

    func testCmdShiftPTogglesMarkdownPreview() throws {
        app.staticTexts["Test Note"].click()

        let preview = app.scrollViews["markdownPreview"]
        XCTAssertFalse(preview.exists,
                       "Preview should not be visible in edit mode")

        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForExistence(timeout: 3),
                      "Preview should appear after Cmd+Shift+P")

        app.typeKey("p", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(preview.exists,
                       "Preview should disappear after toggling Cmd+Shift+P again")
    }
}
