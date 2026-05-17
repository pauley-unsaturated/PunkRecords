import XCTest

@MainActor
final class EditorUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Use the UI-testing vault path so state restoration (which may reopen
        // a previously-used vault window and bypass the welcome screen) can't
        // make this smoke test flaky.
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    func testAppLaunches() throws {
        // The UI-testing vault is recreated fresh on launch and contains a
        // single "Test Note" doc. Its visibility proves the full chain
        // (window → vault open → file scan → sidebar render) worked.
        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "Test vault should load with Test Note visible after launch")
    }
}
