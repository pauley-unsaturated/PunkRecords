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
        XCTAssertTrue(testNote.waitForExistence(timeout: 10),
                      "Test vault should load with Test Note visible")

        // Open the document so the editor (and the toolbar's AI Chat button) exists.
        testNote.click()
        XCTAssertTrue(app.buttons["AI Chat"].waitForExistence(timeout: 5),
                      "AI Chat toolbar button should appear after a doc is open")
    }

    // MARK: - Chat Panel Toggle

    func testChatButtonTogglesChatPanel() throws {
        // Chat panel should not be visible initially
        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertFalse(chatHeader.exists, "Chat panel should be hidden initially")

        // Click the AI Chat toolbar button
        let chatButton = app.buttons["AI Chat"]
        chatButton.click()

        // Chat panel should now be visible
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3),
                      "Chat panel should appear after clicking button")

        // The input field should be present
        let inputField = app.textFields["Ask about your vault..."]
        XCTAssertTrue(inputField.waitForExistence(timeout: 3),
                      "Chat input field should be visible")

        // Click again to dismiss
        chatButton.click()

        // Give it a moment to animate away
        let disappeared = chatHeader.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Chat panel should hide after toggling off")
    }

    func testChatPanelCloseButton() throws {
        // Open chat panel
        let chatButton = app.buttons["AI Chat"]
        chatButton.click()

        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3))

        // Click the close button (xmark.circle.fill, accessibility label "Close")
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3),
                      "Close button should exist in chat panel")
        closeButton.click()

        // Panel should disappear
        let disappeared = chatHeader.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Chat panel should close via close button")
    }

    // MARK: - Provider Picker

    func testProviderPickerVisibleInChatHeader() throws {
        // The header's provider/scope pickers are SwiftUI `Menu`s, which surface
        // as menuButtons. On macOS their own `.accessibilityIdentifier` is
        // overridden by the chat panel's container id ("chatPanel"), so we can't
        // match the picker's own id — instead verify the header's menu controls
        // appear only once the chat panel is opened.
        XCTAssertEqual(app.menuButtons.matching(identifier: "chatPanel").count, 0,
                       "no chat-panel menus before opening the panel")

        app.buttons["AI Chat"].click()

        let headerMenu = app.menuButtons["chatPanel"].firstMatch
        XCTAssertTrue(headerMenu.waitForExistence(timeout: 3),
                      "Opening the chat panel should reveal its header menu controls (provider picker)")
    }

    func testAttachmentControlsVisibleInComposer() throws {
        app.buttons["AI Chat"].click()

        let attachButton = app.buttons["Attach File"]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 3),
                      "Chat composer should expose an attachment button")

        let tokenEstimate = app.otherElements["Estimated tokens"]
        XCTAssertTrue(tokenEstimate.waitForExistence(timeout: 3),
                      "Chat composer should show a live token estimate")
    }

    // MARK: - Ask AI on Selection

    func testAskAIContextMenuPopulatesChat() throws {
        // Target the NSTextView itself (not its NSScrollView) so that the
        // click reaches the text content and ⌘A actually selects something.
        let editor = app.textViews["editorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5),
                      "Editor text view should appear after opening Test Note")

        editor.click()
        app.typeKey("a", modifierFlags: .command)

        editor.rightClick()

        let askAIItem = app.menuItems["Ask AI About Selection"]
        XCTAssertTrue(askAIItem.waitForExistence(timeout: 3),
                      "'Ask AI About Selection' menu item should appear when text is selected")
        askAIItem.click()

        let chatHeader = app.staticTexts["AI Chat"]
        XCTAssertTrue(chatHeader.waitForExistence(timeout: 3),
                      "Chat panel should open after Ask AI")
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
