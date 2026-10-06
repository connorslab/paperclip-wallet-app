import XCTest

final class PreviewTests: XCTestCase {
    func testSeedImportAndPersistentReceiveAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let importButton = app.buttons["Import 12 or 24 seed words"]
        if importButton.waitForExistence(timeout: 5) {
            importButton.tap()
            let words = app.textViews["import-seed"]
            XCTAssertTrue(words.waitForExistence(timeout: 5))
            words.tap()
            words.typeText("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
            app.buttons["Import wallet"].tap()
        }
        let receive = app.buttons["Receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        app.buttons["Create receive address"].tap()
        let address = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'bcrt1'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let first = address.label
        app.terminate()
        app.launch()
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        app.buttons["Create receive address"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertNotEqual(address.label, first)
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Unified sighash · 0x21"].exists)
    }
}
