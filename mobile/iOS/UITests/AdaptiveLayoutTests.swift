import XCTest

/// Synthetic fixtures only: no wallet credentials, synchronization or payments.
final class AdaptiveLayoutTests: XCTestCase {
	func testAssistanceHealthAndBackupStayReadableInCompactAndWideLayouts() {
		continueAfterFailure = false
		defer { XCUIDevice.shared.orientation = .portrait }
		for (flag, title, control) in [
			("-wallet-health-preview", "Wallet health", "Prepare support report"),
			("-backup-center-preview", "Backup & recovery", "Choose file to check…"),
			("-payment-assistance-preview", "Transaction", "Review fee increase"),
			("-own-transfer-preview", "Send XBT", "Move to my other wallet")
		] {
			XCUIDevice.shared.orientation = .portrait
			let app = XCUIApplication()
			app.launchArguments = ["-build61-preview", flag, "-appearance", "dark"]
			app.launch()
			XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
			let button = app.buttons[control].firstMatch
			for _ in 0..<8 { if button.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
			XCTAssertTrue(button.exists)
			if flag != "-backup-center-preview" { XCTAssertTrue(button.isHittable) }
			capture(app, "Assistance compact " + title)
			XCUIDevice.shared.orientation = .landscapeLeft
			let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
			XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10) == .completed)
			XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
			for _ in 0..<8 { if button.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
			XCTAssertTrue(button.exists)
			if flag != "-backup-center-preview" { XCTAssertTrue(button.isHittable) }
			capture(app, "Assistance wide " + title)
			if flag == "-wallet-health-preview" {
				button.tap()
				let share = app.buttons["Share report…"].firstMatch
				for _ in 0..<8 { if share.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
				XCTAssertTrue(share.isHittable)
			}
			app.terminate()
		}
	}

	func testTabSelectionAndNestedBackRemainStable() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-wallet-shell-preview", "-appearance", "dark"]
		app.launch()
		let settings = app.tabBars.buttons["Settings"]
		XCTAssertTrue(settings.waitForExistence(timeout: 15))
		settings.tap()
		XCTAssertTrue(settings.isSelected)
		let recovery = app.buttons["settings-recovery"]
		XCTAssertTrue(recovery.waitForExistence(timeout: 10))
		recovery.tap()
		let security = app.buttons["settings-security"]
		for _ in 0..<6 { if security.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(security.isHittable)
		security.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		app.tabBars.buttons["Wallet"].tap()
		XCTAssertTrue(app.tabBars.buttons["Wallet"].isSelected)
		XCTAssertTrue(app.staticTexts["Total balance"].waitForExistence(timeout: 10))
		settings.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(settings.isSelected)
		app.navigationBars["Wallet security"].buttons.firstMatch.tap()
		XCTAssertTrue(app.navigationBars["Security & recovery"].waitForExistence(timeout: 10))
		app.navigationBars["Security & recovery"].buttons.firstMatch.tap()
		XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
		XCTAssertTrue(settings.isSelected)
		capture(app, "Settings navigation wide")
	}

	func testDashboardReflowsWithoutLosingBalanceVisibility() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-dashboard-preview", "-appearance", "dark"]
		app.launch()
		let hero = app.staticTexts["Total balance"]
		let account = app.staticTexts["On-chain"]
		XCTAssertTrue(hero.waitForExistence(timeout: 15))
		XCTAssertTrue(app.buttons["Send"].isHittable)
		XCTAssertTrue(app.buttons["Receive"].isHittable)
		XCTAssertGreaterThan(account.frame.minY, hero.frame.maxY)
		app.buttons["Toggle balance visibility"].tap()
		XCUIDevice.shared.orientation = .landscapeLeft
		let sideBySide = NSPredicate { _, _ in account.frame.minX > hero.frame.maxX }
		expectation(for: sideBySide, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		XCTAssertTrue(app.staticTexts.matching(identifier: "Balance hidden").firstMatch.exists)
		capture(app, "Wallet wide")
		XCUIDevice.shared.orientation = .portrait
		let stacked = NSPredicate { _, _ in account.frame.minY > hero.frame.maxY }
		expectation(for: stacked, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		XCTAssertTrue(app.staticTexts.matching(identifier: "Balance hidden").firstMatch.exists)
		capture(app, "Wallet compact")
	}

	func testWelcomeHasOneClearCreationPathAndKeepsTheName() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-appearance", "dark"]
		app.launch()
		let create = app.buttons["create-wallet"]
		XCTAssertTrue(create.waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Mobile wallet"].exists)
		XCTAssertTrue(app.staticTexts["Your keys. Your bitcoin."].exists)
		XCTAssertEqual(app.buttons.matching(identifier: "create-wallet").count, 1)
		let name = app.textFields["Wallet name"]
		name.tap(); name.typeText(" 2")
		let editedName = name.value as? String
		XCTAssertTrue(editedName?.contains("2") == true)
		app.buttons["wallet-name-done"].tap()
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertEqual(name.value as? String, editedName)
		capture(app, "Welcome wide")
		XCUIDevice.shared.orientation = .portrait
		XCTAssertEqual(name.value as? String, editedName)
		capture(app, "Welcome compact")
		// Enter only the preparation sheet; never generate or display recovery words.
		create.tap()
		XCTAssertTrue(app.buttons["Generate 24 words"].waitForExistence(timeout: 10))
	}

	func testWelcomeRecoveryRemainsReachableWithLargeText() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		let app = XCUIApplication()
		app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
		app.launch()
		let create = app.buttons["create-wallet"]
		XCTAssertTrue(create.waitForExistence(timeout: 15))
		for _ in 0..<10 { if create.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(create.isHittable)
		let restore = app.buttons["import-seed-words"]
		for _ in 0..<10 { if restore.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(restore.isHittable)
		restore.tap()
		XCTAssertTrue(app.staticTexts["Import your seed"].waitForExistence(timeout: 10))
		app.buttons["import-back"].tap()
		XCTAssertFalse(app.staticTexts["Mobile wallet"].exists)
		let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore a backup")).firstMatch
		for _ in 0..<10 { if backup.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(backup.isHittable)
		backup.tap()
		let bar = app.navigationBars["Restore backup"]
		XCTAssertTrue(bar.waitForExistence(timeout: 10))
		XCTAssertTrue(bar.buttons.firstMatch.isHittable)
		bar.buttons.firstMatch.tap()
	}

	func testNodeConnectionLabelsAndDraftSurviveRotation() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-node-connection-preview", "-appearance", "dark"]
		app.launch()
		let address = app.textFields["node-rest-address"]
		XCTAssertTrue(address.waitForExistence(timeout: 15))
		address.tap()
		address.typeText("https://node.example.invalid")
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertEqual(address.value as? String, "https://node.example.invalid")
		XCTAssertTrue(app.staticTexts["REST address"].exists)
		XCTAssertTrue(app.staticTexts["Privacy & verification"].exists)
		capture(app, "Node connection wide")
		XCUIDevice.shared.orientation = .portrait
		XCTAssertEqual(address.value as? String, "https://node.example.invalid")
		capture(app, "Node connection compact")
	}

	func testLightningReflows() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-lightning-balance-preview", "-appearance", "dark"]
		app.launch()
		let balance = app.staticTexts["Funds in active channels"]
		let bridge = app.staticTexts["Paperclip Bridge"]
		XCTAssertTrue(balance.waitForExistence(timeout: 15))
		XCTAssertGreaterThan(bridge.frame.minY, balance.frame.maxY)
		XCUIDevice.shared.orientation = .landscapeLeft
		expectation(for: NSPredicate { _, _ in bridge.frame.minX > balance.frame.maxX }, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		capture(app, "Lightning wide")
	}

	func testAccessibilityTextStacksWideLayout() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .landscapeLeft
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-lightning-balance-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
		app.launch()
		let balance = app.staticTexts["Funds in active channels"]
		let bridge = app.staticTexts["Paperclip Bridge"]
		XCTAssertTrue(balance.waitForExistence(timeout: 15))
		XCTAssertGreaterThan(bridge.frame.minY, balance.frame.maxY)
		capture(app, "Lightning accessibility")
	}

	func testPendingReceiptDoesNotCelebrateCompletion() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-receipt-preview"]
		app.launch()
		XCTAssertTrue(app.staticTexts["Ark deposit started"].waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Payment completed"].exists)
		XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'registration with the Ark server'")).firstMatch.exists)
		capture(app, "Deposit pending, not completed")
	}

	func testCompletedReceiptHasClearSuccessState() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-receipt-preview", "-completed-receipt-preview"]
		app.launch()
		XCTAssertTrue(app.staticTexts["Payment completed"].waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Payment pending"].exists)
		XCTAssertTrue(app.buttons["Done"].isHittable)
		capture(app, "Verified payment complete")
	}

	func testLiveStartOSLANConnections() throws {
		try XCTSkipIf(ProcessInfo.processInfo.environment["PAPERCLIP_LIVE_NODE_TESTS"] != "1", "Requires private simulator input and explicit live-test opt-in")
		continueAfterFailure = false
		for fixture in ["cln-lan", "lnd-lan"] {
			let app = XCUIApplication()
			app.launchArguments = ["-build61-preview", "-node-connection-preview", "-live-node-case", fixture]
			app.launch()
			let verify = app.buttons["Verify and save connection"]
			XCTAssertTrue(verify.waitForExistence(timeout: 15))
			for _ in 0..<8 { if verify.isHittable { break }; app.swipeUp() }
			XCTAssertTrue(verify.isHittable)
			verify.tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.waitForExistence(timeout: 90))
			XCTAssertTrue(app.buttons["Refresh Lightning balance"].exists)
			app.buttons["Refresh Lightning balance"].tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.exists)
			app.terminate()
		}
	}

	private func capture(_ app: XCUIApplication, _ name: String) {
		// Element screenshots can crop using stale portrait bounds after rotation.
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
