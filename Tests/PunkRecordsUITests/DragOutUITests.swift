import XCTest

/// Verifies that the file URL bound to `.draggable(fileURL)` on a sidebar
/// row points to the right path on disk.
///
/// **Why not a real gesture test:** XCUITest's synthetic drag from a SwiftUI
/// List row + NSTableView doesn't trigger SwiftUI's `.draggable` handler on
/// macOS. Several gesture flavors were tried (press+drag on static text, on
/// the cell, coordinate-based with `.slow` velocity and hold) — none of them
/// fire the drop callback against an in-app `.onDrop(of: [.fileURL])` zone
/// in either NavigationSplitView pane. The platform mechanics work in
/// production (manual drag-out to Finder is correct), so we verify the
/// contract instead: the row exposes the same URL that `.draggable` would
/// hand to the receiver, via accessibilityValue under --ui-testing.
@MainActor
final class DragOutUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["Test Note"].waitForExistence(timeout: 10),
                      "UI-test vault should load with Test Note visible")
    }

    func testDocumentRowExposesItsDraggableFileURL() throws {
        let scratchCell = app.outlines.cells
            .containing(.staticText, identifier: "Scratch Note")
            .firstMatch
        XCTAssertTrue(scratchCell.waitForExistence(timeout: 3),
                      "Should find the cell wrapping 'Scratch Note'")

        // The Label's accessibilityValue mirrors what .draggable hands out.
        // Drilling into the cell finds the Label element that owns the value.
        let labelInside = scratchCell.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] 'scratch-note.md'"))
            .firstMatch
        XCTAssertTrue(labelInside.waitForExistence(timeout: 3),
                      "Scratch Note row should expose a file URL ending in 'scratch-note.md' as its accessibilityValue")

        // Sanity: it's an absolute file path, ending in our test filename
        // inside the PunkRecords-UITest temp vault.
        let value = labelInside.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix("/scratch-note.md"),
                      "Expected value to end in '/scratch-note.md' but was \(value)")
        XCTAssertTrue(value.contains("PunkRecords-UITest"),
                      "Expected value to be inside the UI-test vault, got \(value)")
    }
}
