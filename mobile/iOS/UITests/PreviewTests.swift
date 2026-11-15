import XCTest

final class PreviewTests: XCTestCase {
    func testSeedImportAndPersistentReceiveAddress() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let importButton = app.buttons["import-seed-words"]
        if importButton.waitForExistence(timeout: 5) {
            importButton.tap()
            let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            for (index, word) in seed.split(separator: " ").enumerated() {
                let field = app.textFields["import-word-\(index + 1)"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                if index == 0 { field.tap() }
                field.typeText(String(word) + "\n")
            }
            let importWallet = app.buttons["Import wallet"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: importWallet)
            waitForExpectations(timeout: 5)
            for _ in 0..<5 { if importWallet.isHittable { break }; app.swipeUp() }
            importWallet.tap()
        }
        let receive = app.buttons["Receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        let switcher = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Active wallet:'")).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "value BEGINSWITH 'Selected. '")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        receive.tap()
        app.buttons["Create receive address"].tap()
        let fullAddress = app.buttons["View full address or request"]
        XCTAssertTrue(fullAddress.waitForExistence(timeout: 10))
        fullAddress.tap()
        let address = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'bcrt1'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let first = address.label
        app.terminate()
        app.launch()
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        app.buttons["Create receive address"].tap()
        XCTAssertTrue(fullAddress.waitForExistence(timeout: 10))
        fullAddress.tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertNotEqual(address.label, first)
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings-security"].tap()
        XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unified sighash · 0x21'")).firstMatch.waitForExistence(timeout: 10))
    }
}
