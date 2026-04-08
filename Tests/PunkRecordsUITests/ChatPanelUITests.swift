import XCTest

@MainActor
final class ChatPanelUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Launch app with --ui-testing flag so it creates a temp vault
        app.launchArguments.append("--ui-testing")
        app.launch()

        // Wait for vault to load — the test doc should appear in the sidebar
        let testNote = app.staticTexts["Test Note"]
        XCTAssertTrue(testNote.waitForExistence(timeout: 10), "Test vault should load with Test Note visible")
    }

    // MARK: - Chat Panel Toggle

    func testChatButtonTogglesChatPanel() throws {
        // Click a document to open the editor (which has the AI Chat button)
        selectFirstDocument()

        // Chat panel should not be visible initially
        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertFalse(chatHeader.exists, "Chat panel should be hidden initially")

        // Click the AI Chat toolbar button
        let chatButton = app.buttons["AI Chat"]
        XCTAssertTrue(chatButton.waitForExistence(timeout: 5), "AI Chat button should exist in toolbar")
        chatButton.click()

        // Chat panel should now be visible
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3), "Chat panel should appear after clicking button")

        // The input field should be present
        let inputField = app.textFields["Ask about your knowledge base..."]
        XCTAssertTrue(inputField.waitForExistence(timeout: 3), "Chat input field should be visible")

        // Click again to dismiss
        chatButton.click()

        // Give it a moment to animate away
        let disappeared = chatHeader.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Chat panel should hide after toggling off")
    }

    func testChatPanelCloseButton() throws {
        selectFirstDocument()

        // Open chat panel
        let chatButton = app.buttons["AI Chat"]
        XCTAssertTrue(chatButton.waitForExistence(timeout: 5))
        chatButton.click()

        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3))

        // Click the close button (xmark.circle.fill)
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3), "Close button should exist in chat panel")
        closeButton.click()

        // Panel should disappear
        let disappeared = chatHeader.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Chat panel should close via close button")
    }

    // MARK: - Ask AI on Selection

    func testAskAIContextMenuPopulatesChat() throws {
        selectFirstDocument()

        // Wait for the editor text view to load
        let textView = app.scrollViews.firstMatch
        guard textView.waitForExistence(timeout: 5) else {
            XCTFail("Editor text view should appear")
            return
        }

        // Select all text
        textView.click()
        app.typeKey("a", modifierFlags: .command)

        // Right-click to get context menu
        textView.rightClick()

        // Look for our custom menu item
        let askAIItem = app.menuItems["Ask AI About Selection"]
        guard askAIItem.waitForExistence(timeout: 3) else {
            XCTFail("'Ask AI About Selection' menu item should appear when text is selected")
            return
        }
        askAIItem.click()

        // The chat panel should now be visible
        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3),
                      "Chat panel should open after Ask AI")
    }

    // MARK: - Helpers

    private func selectFirstDocument() {
        // Try collection views first (modern SwiftUI List), then outlines
        let collections = app.collectionViews
        if collections.count > 0 {
            let firstCell = collections.firstMatch.cells.firstMatch
            if firstCell.waitForExistence(timeout: 5) {
                firstCell.click()
                return
            }
        }

        let outlines = app.outlines
        if outlines.count > 0 {
            let firstRow = outlines.firstMatch.cells.firstMatch
            if firstRow.waitForExistence(timeout: 5) {
                firstRow.click()
                return
            }
        }

        // Last resort: try any clickable text that looks like a doc
        let docLabel = app.staticTexts["Test Note"]
        if docLabel.waitForExistence(timeout: 5) {
            docLabel.click()
        }
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
