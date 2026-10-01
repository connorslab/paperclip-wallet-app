import XCTest

final class PreviewTests: XCTestCase {
    func testNativeEngineAndUnfundedPreview() {
        let app = XCUIApplication()
        app.launch()
        let engine = app.staticTexts["engine-status"]
        XCTAssertTrue(engine.waitForExistence(timeout: 20))
        XCTAssertTrue(engine.label.contains("key derivation passed"))
        XCTAssertTrue(app.staticTexts["Regtest development build. Do not send mainnet funds. Open the wallet lab to create or connect a test wallet."].exists)
    }
    func testNativeWalletSurvivesAppRestart() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["wallet-lab"].tap()
        app.buttons["create-test-wallet"].tap()
        let identity = app.staticTexts["wallet-fingerprint"]
        XCTAssertTrue(identity.waitForExistence(timeout: 30))
        let fingerprint = identity.label
        app.swipeUp()
        app.buttons["new-onchain-address"].tap()
        let address = app.staticTexts["receive-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let first = address.label
        XCTAssertTrue(first.hasPrefix("bcrt1"))
        app.terminate()
        app.launch()
        app.buttons["wallet-lab"].tap()
        app.buttons["Reopen saved wallet"].tap()
        XCTAssertTrue(identity.waitForExistence(timeout: 30))
        XCTAssertEqual(identity.label, fingerprint)
        app.swipeUp()
        app.buttons["new-onchain-address"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertNotEqual(address.label, first)
    }
}
