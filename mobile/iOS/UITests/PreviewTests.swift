import XCTest

final class PreviewTests: XCTestCase {
    func testNativeEngineAndUnfundedPreview() {
        let app = XCUIApplication()
        app.launch()
        let engine = app.staticTexts["engine-status"]
        XCTAssertTrue(engine.waitForExistence(timeout: 20))
        XCTAssertTrue(engine.label.contains("key derivation passed"))
        XCTAssertTrue(app.staticTexts["No wallet is connected. This build cannot receive funds or make payments."].exists)
    }
}
