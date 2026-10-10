import XCTest

final class TagMP3UITests: XCTestCase {
    func testInitialWorkspaceShowsEmptyState() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["No Tracks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inspector"].waitForExistence(timeout: 5))
    }
}
