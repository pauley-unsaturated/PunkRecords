import XCTest

/// End-to-end chat turn against the scripted session model.
///
/// Launching with `--ui-testing-scripted-chat` makes `LanguageModelFactory`
/// resolve every provider to a deterministic `ScriptedLanguageModel` (no
/// network, no keys) whose script performs one `vault_search` tool round and
/// then answers. That exercises the REAL shipping pipeline —
/// `LLMChatPanel.sendAgentMessage` → `SessionAgentRunner` round loop →
/// `EventEmittingToolAdapter` → real `VaultSearchTool` over the temp vault —
/// with only the model itself canned.
@MainActor
final class ChatTurnUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false

        app.launchArguments += ["--ui-testing", "--ui-testing-scripted-chat"]
        app.launch()

        // Wait for the temp vault, open the test doc, then open the chat panel.
        let testNote = app.staticTexts["Test Note"]
        XCTAssertTrue(testNote.waitForExistence(timeout: 10),
                      "Test vault should load with Test Note visible")
        testNote.click()

        let chatButton = app.buttons["AI Chat"]
        XCTAssertTrue(chatButton.waitForExistence(timeout: 5),
                      "AI Chat toolbar button should appear after a doc is open")
        chatButton.click()
        XCTAssertTrue(app.staticTexts["AI Chat"].waitForExistence(timeout: 3),
                      "Chat panel should open")
    }

    // MARK: - Full chat turn

    func testSendMessageDrivesToolCallAndScriptedResponse() throws {
        let input = app.textFields["Ask about your vault..."]
        XCTAssertTrue(input.waitForExistence(timeout: 3), "Chat input should be visible")
        input.click()
        input.typeText("What's in my vault?")

        // Send via the send button (more deterministic than Return for a
        // vertical-axis SwiftUI TextField).
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.click()

        // The scripted model's tool round renders a vault_search chip
        // ("Search vault") that completes without error.
        let toolChip = app.staticTexts["Search vault"]
        XCTAssertTrue(toolChip.waitForExistence(timeout: 10),
                      "vault_search tool bubble should render during the turn")

        // The scripted answer lands as an assistant bubble.
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "Scripted response", "Scripted response")
        let response = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 10),
                      "Scripted assistant text should render after the tool round")
    }

    // MARK: - Provider picker states

    func testProviderPickerListsAndSwitchesProviders() throws {
        // Under scripted mode every provider reports available, so the menu's
        // contents are deterministic: all four entries listed and selectable.
        // Neither `isEnabled` nor the picker's label is reliably surfaced
        // through accessibility for SwiftUI menus, so assert BEHAVIOR: after
        // selecting a provider, the next assistant message must be attributed
        // to it ("via Ollama") — a disabled item can't change the selection.
        // (On macOS the pickers surface under the panel's container identifier,
        // provider picker first in document order.)
        let providerMenu = app.menuButtons.matching(identifier: "chatPanel").element(boundBy: 0)
        XCTAssertTrue(providerMenu.waitForExistence(timeout: 3),
                      "Provider picker should exist in the chat header")

        providerMenu.click()
        for name in ["Apple", "Claude", "GPT", "Ollama"] {
            XCTAssertTrue(app.menuItems[name].waitForExistence(timeout: 3),
                          "\(name) should be listed in the provider menu")
        }
        app.typeKey(.escape, modifierFlags: [])

        // Availability populates asynchronously (items stay disabled until the
        // first probe lands), so retry. Type BEFORE touching the menu — menu
        // interaction steals keyboard focus from the field — then select the
        // provider and send.
        var attributed = false
        for attempt in 0..<5 where !attributed {
            let input = app.textFields["Ask about your vault..."]
            XCTAssertTrue(input.waitForExistence(timeout: 3))
            input.click()
            input.typeText("attribution check \(attempt)")

            providerMenu.click()
            let item = app.menuItems["Ollama"]
            guard item.waitForExistence(timeout: 2) else {
                app.typeKey(.escape, modifierFlags: [])
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            item.click()

            app.buttons["Send message"].click()

            // A no-op selection (item still disabled) sends attributed to the
            // previous provider; retry with a fresh message in that case.
            attributed = app.staticTexts["via Ollama"].waitForExistence(timeout: 8)
            if !attributed { Thread.sleep(forTimeInterval: 2) }
        }
        XCTAssertTrue(attributed,
                      "After selecting Ollama, the assistant reply should be attributed 'via Ollama'")

        // Leave the persisted selection on the default (Claude). firstMatch:
        // after messages exist, more than one element can carry the title.
        providerMenu.click()
        let claudeItem = app.menuItems["Claude"].firstMatch
        if claudeItem.waitForExistence(timeout: 2) {
            claudeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
