import XCTest

/// Covers the ⌘O Quick Open palette added in Editor W5 (PUNK-i7r).
@MainActor
final class QuickOpenUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load with Test Note visible")
    }

    func testCmdOOpensQuickOpenPalette() throws {
        app.typeKey("o", modifierFlags: [.command])

        let field = app.textFields["quickOpenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "⌘O should open the Quick Open palette")

        // Escape dismisses; verify the field disappears.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(field.waitForExistence(timeout: 1),
                       "Escape should dismiss the Quick Open palette")
    }

    func testTypingThenEnterOpensMatchedNote() throws {
        app.typeKey("o", modifierFlags: [.command])
        let field = app.textFields["quickOpenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))

        // Fuzzy-match "scratch" -> Scratch Note (created by the UI-test vault).
        field.click()
        field.typeText("scratch")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        // After dismissing, the editor's nav title should reflect the chosen doc.
        // The Scratch Note has H1 "# Scratch Note" so the window title becomes
        // "Scratch Note".
        XCTAssertTrue(
            app.windows["Scratch Note"].waitForExistence(timeout: 3)
            || app.staticTexts["Scratch Note"].waitForExistence(timeout: 3),
            "Selecting Scratch Note in Quick Open should open it in the editor"
        )
    }
}
