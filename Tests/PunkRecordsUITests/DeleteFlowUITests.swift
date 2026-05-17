import XCTest

/// Covers the right-click → Move to Trash → confirm flow on a sidebar row.
/// The UI-test vault has two notes so deleting one doesn't leave the vault
/// empty (which would break other tests' setUp assumptions).
@MainActor
final class DeleteFlowUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load with Test Note visible")
        XCTAssertTrue(app.staticTexts["Scratch Note"].exists,
                      "UI-test vault should also expose Scratch Note for delete-flow tests")
    }

    func testRightClickMoveToTrashConfirmsAndRemovesRow() throws {
        let scratchRow = app.staticTexts["Scratch Note"]
        scratchRow.rightClick()

        let moveToTrash = app.menuItems["Move to Trash"]
        XCTAssertTrue(moveToTrash.waitForExistence(timeout: 3),
                      "Context menu should expose 'Move to Trash'")
        moveToTrash.click()

        // SwiftUI's confirmationDialog on macOS surfaces as a sheet
        // attached to the host window, not a separate Dialog element.
        let confirmButton = confirmationButton(label: "Move to Trash")
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3),
                      "Confirmation sheet should appear with a 'Move to Trash' button")
        confirmButton.click()

        XCTAssertTrue(scratchRow.waitForNonExistence(timeout: 5),
                      "Scratch Note row should disappear after confirming deletion")
        XCTAssertTrue(app.staticTexts["Test Note"].exists,
                      "Test Note should remain — only the right-clicked row gets deleted")
    }

    func testCancelLeavesRowInPlace() throws {
        let scratchRow = app.staticTexts["Scratch Note"]
        scratchRow.rightClick()

        app.menuItems["Move to Trash"].click()

        let cancelButton = confirmationButton(label: "Cancel")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3),
                      "Confirmation sheet should expose a Cancel button")
        cancelButton.click()

        // Give the sheet a beat to dismiss.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(scratchRow.exists,
                      "Cancelling the confirmation should leave Scratch Note untouched")
    }

    /// Look in sheets first (where SwiftUI's confirmationDialog actually
    /// renders on macOS) and fall back to top-level app buttons if the
    /// dialog was attached differently.
    private func confirmationButton(label: String) -> XCUIElement {
        let sheetButton = app.sheets.buttons[label]
        if sheetButton.exists { return sheetButton }
        return app.buttons[label]
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
