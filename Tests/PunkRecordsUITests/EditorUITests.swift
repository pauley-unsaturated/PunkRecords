import XCTest

@MainActor
final class EditorUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testAppLaunches() throws {
        // Verify the app launches and shows the vault picker
        XCTAssertTrue(app.staticTexts["PunkRecords"].waitForExistence(timeout: 5))
    }
}
